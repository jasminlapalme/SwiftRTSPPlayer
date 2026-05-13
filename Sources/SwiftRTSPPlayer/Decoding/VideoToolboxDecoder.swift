//
//  VideoToolboxDecoder.swift
//  LecteurRTSP
//
//  Created by Jasmin Lapalme on 2026-03-30.
//

import Foundation
import VideoToolbox
import AVFoundation
import os

private let log = Logger(subsystem: "SwiftRTSPPlayer", category: "VideoToolboxDecoder")

// Scoped, narrow `@unchecked Sendable` courier that hands a freshly decoded
// `CVPixelBuffer` from the VideoToolbox callback thread to the decoder actor.
// Each buffer is owned by exactly one task at a time, so the unchecked claim is
// safe here even though `CVPixelBuffer` is not generally `Sendable`.
private struct SendablePixelBuffer: @unchecked Sendable {
	let buffer: CVPixelBuffer
}

// RAII wrapper passed as the VideoToolbox callback refcon. The actor holds
// the box strongly, so its lifetime is tied to the actor and tear-down is a
// single `refconBox = nil` — no manual passRetained/passUnretained release
// pairing to drop on the floor if a future code path throws between the two.
// `unowned` is safe because the actor outlives the box by construction.
private final class CallbackRefcon {
	unowned let decoder: VideoToolboxDecoder
	init(_ decoder: VideoToolboxDecoder) { self.decoder = decoder }
}

actor VideoToolboxDecoder {

	private var session: VTDecompressionSession?
	private var formatDesc: CMFormatDescription?
	private var nalUnitHeaderLength = 4
	private var hasReceivedIDR = false

	private var continuation: AsyncStream<DecodedFrame>.Continuation?
	private var ptsQueue: [CMTime] = []
	private var refconBox: CallbackRefcon?

	// MARK: - Public stream

	func frames() -> AsyncStream<DecodedFrame> {
		AsyncStream { continuation in
			self.continuation = continuation
		}
	}

	// MARK: - Configure

	func configure(sps: Data, pps: Data, nalUnitHeaderLength: Int = 4) throws {
		invalidate()
		self.nalUnitHeaderLength = nalUnitHeaderLength

		let formatDescOut = try makeFormatDescription(sps: sps, pps: pps, nalUnitHeaderLength: nalUnitHeaderLength)
		self.formatDesc = formatDescOut

		let refcon = CallbackRefcon(self)
		self.refconBox = refcon
		var callback = VTDecompressionOutputCallbackRecord(
			decompressionOutputCallback: decompressionCallback,
			decompressionOutputRefCon: Unmanaged.passUnretained(refcon).toOpaque()
		)

		self.session = try makeDecompressionSession(
			formatDesc: formatDescOut,
			callback: &callback,
			sps: sps,
			pps: pps,
			nalUnitHeaderLength: nalUnitHeaderLength
		)
	}

	private func makeFormatDescription(
		sps: Data,
		pps: Data,
		nalUnitHeaderLength: Int
	) throws -> CMFormatDescription {
		var formatDescOut: CMFormatDescription?
		let status: OSStatus = sps.withUnsafeBytes { spsBytes in
			pps.withUnsafeBytes { ppsBytes in
				guard let spsBase = spsBytes.baseAddress,
							let ppsBase = ppsBytes.baseAddress else {
					return kCMFormatDescriptionError_InvalidParameter
				}

				var parameterSetPointers: [UnsafePointer<UInt8>] = [
					spsBase.assumingMemoryBound(to: UInt8.self),
					ppsBase.assumingMemoryBound(to: UInt8.self)
				]
				var parameterSetSizes: [Int] = [sps.count, pps.count]

				return CMVideoFormatDescriptionCreateFromH264ParameterSets(
					allocator: kCFAllocatorDefault,
					parameterSetCount: 2,
					parameterSetPointers: &parameterSetPointers,
					parameterSetSizes: &parameterSetSizes,
					nalUnitHeaderLength: Int32(nalUnitHeaderLength),
					formatDescriptionOut: &formatDescOut
				)
			}
		}

		guard status == noErr, let formatDescOut else {
			throw NSError(
				domain: "Decoder",
				code: Int(status),
				userInfo: [
					NSLocalizedDescriptionKey: String(localized: "error.cannotCreateFormatDescription", bundle: .module)
				]
			)
		}

		return formatDescOut
	}

	private func makeDecompressionSession(
		formatDesc: CMFormatDescription,
		callback: inout VTDecompressionOutputCallbackRecord,
		sps: Data,
		pps: Data,
		nalUnitHeaderLength: Int
	) throws -> VTDecompressionSession {
		#if targetEnvironment(simulator)
		let decoderSpecification: [CFString: Any] = [:]
		#else
		let decoderSpecification: [CFString: Any] = [
			kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true
		]
		#endif

		let imageBufferAttributes: [CFString: Any] = [
			kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
			kCVPixelBufferMetalCompatibilityKey: true
		]

		var sessionOut: VTDecompressionSession?
		let createStatus = VTDecompressionSessionCreate(
			allocator: kCFAllocatorDefault,
			formatDescription: formatDesc,
			decoderSpecification: decoderSpecification as CFDictionary,
			imageBufferAttributes: imageBufferAttributes as CFDictionary,
			outputCallback: &callback,
			decompressionSessionOut: &sessionOut
		)
		log.debug("VTDecompressionSessionCreate status: \(createStatus, privacy: .public)")

		guard createStatus == noErr, let sessionOut else {
			// No session will ever fire callbacks against the refcon — drop it now.
			self.refconBox = nil
			let dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc)
			throw NSError(
				domain: "Decoder",
				code: Int(createStatus),
				userInfo: [
					NSLocalizedDescriptionKey: String(localized: "error.cannotCreateDecompressionSession", bundle: .module),
					"width": Int(dimensions.width),
					"height": Int(dimensions.height),
					"nalUnitHeaderLength": nalUnitHeaderLength,
					"spsLength": sps.count,
					"ppsLength": pps.count
				]
			)
		}

		return sessionOut
	}

	// MARK: - Decode

	// Hard ceiling on `ptsQueue` so a hostile stream that gets VT to accept
	// frames without ever emitting callbacks (e.g. reference frames stuck in
	// a reorder buffer on corrupt input) can't grow the queue without bound.
	// 300 ≈ 10 s at 30 fps, well above any realistic H.264 reorder window.
	private static let maxPendingPTS = 300

	func decode(avccData: Data, pts: CMTime, dts: CMTime) {
		guard let session, let formatDesc else { return }
		guard let cleanData = filterNALUs(avccData), !cleanData.isEmpty else { return }
		guard let blockBuffer = makeBlockBuffer(from: cleanData) else { return }
		guard let sampleBuffer = makeSampleBuffer(
			blockBuffer: blockBuffer,
			formatDesc: formatDesc,
			size: cleanData.count,
			pts: pts,
			dts: dts
		) else { return }

		// Past this point we're committed: every failure path explicitly
		// removes the entry it appends. Setup completed without leaks.
		if ptsQueue.count >= Self.maxPendingPTS {
			ptsQueue.removeFirst()
		}
		ptsQueue.append(pts)

		let decodeStatus = VTDecompressionSessionDecodeFrame(
			session,
			sampleBuffer: sampleBuffer,
			flags: [._EnableAsynchronousDecompression],
			frameRefcon: nil,
			infoFlagsOut: nil
		)

		if decodeStatus != noErr {
			log.error("VTDecompressionSessionDecodeFrame failed: \(decodeStatus, privacy: .public)")
			ptsQueue.removeLast()
		}
	}

	private func makeBlockBuffer(from data: Data) -> CMBlockBuffer? {
		var blockBuffer: CMBlockBuffer?
		let size = data.count

		guard CMBlockBufferCreateWithMemoryBlock(
			allocator: kCFAllocatorDefault,
			memoryBlock: nil,
			blockLength: size,
			blockAllocator: kCFAllocatorDefault,
			customBlockSource: nil,
			offsetToData: 0,
			dataLength: size,
			flags: 0,
			blockBufferOut: &blockBuffer
		) == kCMBlockBufferNoErr,
		let blockBuffer else { return nil }

		let status = data.withUnsafeBytes { rawBuffer -> OSStatus in
			guard let baseAddress = rawBuffer.baseAddress else {
				return kCMBlockBufferBadPointerParameterErr
			}
			return CMBlockBufferReplaceDataBytes(
				with: baseAddress,
				blockBuffer: blockBuffer,
				offsetIntoDestination: 0,
				dataLength: size
			)
		}

		return status == kCMBlockBufferNoErr ? blockBuffer : nil
	}

	private func makeSampleBuffer(
		blockBuffer: CMBlockBuffer,
		formatDesc: CMFormatDescription,
		size: Int,
		pts: CMTime,
		dts: CMTime
	) -> CMSampleBuffer? {
		var sampleBuffer: CMSampleBuffer?
		var sampleSize = size
		var timing = CMSampleTimingInfo(
			duration: .invalid,
			presentationTimeStamp: pts,
			decodeTimeStamp: dts
		)

		guard CMSampleBufferCreateReady(
			allocator: kCFAllocatorDefault,
			dataBuffer: blockBuffer,
			formatDescription: formatDesc,
			sampleCount: 1,
			sampleTimingEntryCount: 1,
			sampleTimingArray: &timing,
			sampleSizeEntryCount: 1,
			sampleSizeArray: &sampleSize,
			sampleBufferOut: &sampleBuffer
		) == noErr else { return nil }

		return sampleBuffer
	}

	// MARK: - Cleanup

	func invalidate() {
		if let session {
			// Drain any callbacks already queued in VT's pipeline before tearing down.
			// After this, no further callbacks can fire against `refconBox`.
			VTDecompressionSessionFinishDelayedFrames(session)
			VTDecompressionSessionInvalidate(session)
			self.session = nil
			self.refconBox = nil
		}
		formatDesc = nil
		nalUnitHeaderLength = 4
		hasReceivedIDR = false
		ptsQueue.removeAll()
	}

	func flush() {
		guard let session else { return }
		VTDecompressionSessionFinishDelayedFrames(session)
	}

	// MARK: - Callback

	// Fires on VideoToolbox's internal thread pool — must not touch actor state directly.
	// All state mutations are serialised by hopping onto the actor via Task.
	private let decompressionCallback: VTDecompressionOutputCallback = { refCon, _, status, _, imageBuffer, _, _ in
		guard status == noErr, let imageBuffer, let refCon else {
			if status != noErr {
				log.error("VT decompression callback failed: \(status, privacy: .public)")
			}
			return
		}

		let box = Unmanaged<CallbackRefcon>
			.fromOpaque(refCon)
			.takeUnretainedValue()
		let decoder = box.decoder

		let courier = SendablePixelBuffer(buffer: imageBuffer)
		Task { await decoder.handleDecodedFrame(courier.buffer) }
	}

	func handleDecodedFrame(_ imageBuffer: CVPixelBuffer) {
		let pts = ptsQueue.isEmpty ? CMTime.invalid : ptsQueue.removeFirst()
		continuation?.yield(DecodedFrame(pixelBuffer: imageBuffer, pts: pts))
	}

}

// MARK: - NALU filtering

private extension VideoToolboxDecoder {

	func filterNALUs(_ data: Data) -> Data? {
		var offset = 0
		var filtered = Data()

		while offset + nalUnitHeaderLength <= data.count {
			let length = data[offset..<offset + nalUnitHeaderLength].reduce(UInt32(0)) {
				($0 << 8) | UInt32($1)
			}
			offset += nalUnitHeaderLength

			guard length > 0, offset + Int(length) <= data.count else {
				return nil
			}

			let nalu = data[offset..<offset + Int(length)]
			offset += Int(length)

			guard let header = nalu.first else { continue }
			let type = header & 0x1F

			switch type {
			case 7, 8, 9, 12:
				continue

			case 5:
				hasReceivedIDR = true
				appendNALULength(nalu.count, to: &filtered)
				filtered.append(contentsOf: nalu)

			case 1:
				guard hasReceivedIDR else { continue }
				appendNALULength(nalu.count, to: &filtered)
				filtered.append(contentsOf: nalu)

			default:
				continue
			}
		}

		return filtered.isEmpty ? nil : filtered
	}

	func appendNALULength(_ length: Int, to data: inout Data) {
		// `nalUnitHeaderLength` is bounded to 1...4 by the AVCC parser; the
		// largest length representable in N bytes is `2^(8*N) - 1`. Tripping
		// this means the NALU is too large for the format to encode — fail
		// loudly instead of silently truncating the high bits.
		let maxLength = (1 << (nalUnitHeaderLength * 8)) - 1
		precondition(
			length >= 0 && length <= maxLength,
			"NALU length \(length) exceeds nalUnitHeaderLength=\(nalUnitHeaderLength) capacity"
		)
		for shift in stride(from: (nalUnitHeaderLength - 1) * 8, through: 0, by: -8) {
			data.append(UInt8((length >> shift) & 0xFF))
		}
	}
}

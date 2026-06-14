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
	private var codec: VideoCodec = .h264
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

	func configure(parameterSet: ParameterSet) throws {
		invalidate()
		self.nalUnitHeaderLength = parameterSet.nalUnitHeaderLength
		self.codec = parameterSet.codec

		let formatDescOut = try makeFormatDescription(parameterSet: parameterSet)
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
			parameterSet: parameterSet
		)
	}

	private func makeFormatDescription(parameterSet: ParameterSet) throws -> CMFormatDescription {
		// VideoToolbox takes the parameter sets as an array of (pointer, size).
		// H.264 supplies SPS + PPS; HEVC prepends a VPS.
		let sets: [Data]
		switch parameterSet.codec {
		case .h264:
			sets = [parameterSet.sps, parameterSet.pps]
		case .hevc:
			guard let vps = parameterSet.vps else {
				throw NSError(
					domain: "Decoder",
					code: Int(kCMFormatDescriptionError_InvalidParameter),
					userInfo: [
						NSLocalizedDescriptionKey: String(localized: "error.cannotCreateFormatDescription", bundle: .module)
					]
				)
			}
			sets = [vps, parameterSet.sps, parameterSet.pps]
		}

		var formatDescOut: CMFormatDescription?
		let status = withParameterSetPointers(sets) { pointers, sizes in
			switch parameterSet.codec {
			case .h264:
				return CMVideoFormatDescriptionCreateFromH264ParameterSets(
					allocator: kCFAllocatorDefault,
					parameterSetCount: pointers.count,
					parameterSetPointers: pointers.baseAddress!,
					parameterSetSizes: sizes.baseAddress!,
					nalUnitHeaderLength: Int32(parameterSet.nalUnitHeaderLength),
					formatDescriptionOut: &formatDescOut
				)
			case .hevc:
				return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
					allocator: kCFAllocatorDefault,
					parameterSetCount: pointers.count,
					parameterSetPointers: pointers.baseAddress!,
					parameterSetSizes: sizes.baseAddress!,
					nalUnitHeaderLength: Int32(parameterSet.nalUnitHeaderLength),
					extensions: nil,
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
		parameterSet: ParameterSet
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
					"nalUnitHeaderLength": parameterSet.nalUnitHeaderLength,
					"spsLength": parameterSet.sps.count,
					"ppsLength": parameterSet.pps.count
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
		codec = .h264
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

// MARK: - Parameter set pinning

private extension VideoToolboxDecoder {

	// Recursively pins each parameter set's bytes so all base addresses stay
	// valid for the single CM*FormatDescriptionCreate call — `withUnsafeBytes`
	// guarantees validity only within its own closure, so they must nest.
	func withParameterSetPointers(
		_ sets: [Data],
		_ body: (UnsafeBufferPointer<UnsafePointer<UInt8>>, UnsafeBufferPointer<Int>) -> OSStatus
	) -> OSStatus {
		var pointers: [UnsafePointer<UInt8>] = []
		var sizes: [Int] = []
		func recurse(_ index: Int) -> OSStatus {
			guard index < sets.count else {
				return pointers.withUnsafeBufferPointer { ptrBuf in
					sizes.withUnsafeBufferPointer { sizeBuf in
						body(ptrBuf, sizeBuf)
					}
				}
			}
			return sets[index].withUnsafeBytes { raw in
				guard let base = raw.baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
				pointers.append(base.assumingMemoryBound(to: UInt8.self))
				sizes.append(sets[index].count)
				return recurse(index + 1)
			}
		}
		return recurse(0)
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

			switch classify(naluHeader: header) {
			case .keyframe:
				hasReceivedIDR = true
				appendNALULength(nalu.count, to: &filtered)
				filtered.append(contentsOf: nalu)

			case .slice:
				// Drop leading P-frames until the first keyframe is seen — feeding
				// VideoToolbox inter-coded frames with no reference corrupts output.
				guard hasReceivedIDR else { continue }
				appendNALULength(nalu.count, to: &filtered)
				filtered.append(contentsOf: nalu)

			case .drop:
				continue
			}
		}

		return filtered.isEmpty ? nil : filtered
	}

	private enum NALUClass {
		case keyframe  // IDR / IRAP — resets the reference state
		case slice     // inter-coded picture slice
		case drop      // parameter set, delimiter, SEI, filler, etc.
	}

	private func classify(naluHeader header: UInt8) -> NALUClass {
		switch codec {
		case .h264:
			switch header & 0x1F {
			case 5: return .keyframe          // IDR slice
			case 1: return .slice             // non-IDR slice
			default: return .drop             // SPS(7)/PPS(8)/AUD(9)/filler(12)/…
			}
		case .hevc:
			let type = (header >> 1) & 0x3F
			switch type {
			// IRAP pictures: BLA (16-18), IDR (19-20), CRA (21).
			case 16...23: return .keyframe
			// Remaining VCL NAL units (0-15, 24-31) are inter-coded slices.
			case 0...31: return .slice
			// 32+ are non-VCL: VPS/SPS/PPS/AUD/EOS/EOB/FD/SEI — already in the
			// format description or irrelevant to the decoder.
			default: return .drop
			}
		}
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

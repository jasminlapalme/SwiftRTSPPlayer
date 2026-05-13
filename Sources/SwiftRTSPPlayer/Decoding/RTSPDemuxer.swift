//
//  RTSPDemuxer.swift
//  LecteurRTSP
//
//  Created by Jasmin Lapalme on 2026-03-30.
//

import Foundation
import CoreMedia
import FFmpeg

public struct VideoFrame: Sendable {
	public let data: Data
	public let pts: CMTime
	public let dts: CMTime
}

public struct ParameterSet: Sendable {
	public let sps: Data
	public let pps: Data
	public let nalUnitHeaderLength: Int
}

public enum RTSPEvent: Sendable {
	case format(ParameterSet)
	case frame(VideoFrame)
	case stopped
}

actor RTSPDemuxer {

	private var task: Task<Void, Never>?

	// MARK: - Public API
	func events(url: URL) -> AsyncThrowingStream<RTSPEvent, Error> {
		AsyncThrowingStream { continuation in

			continuation.onTermination = { [weak self] _ in
				Task { await self?.stop() }
			}
			task = Task.detached { [weak self] in
				guard let self else { return }
				do {
					try self.demuxLoop(url: url) { event in
						continuation.yield(event)
					}
					continuation.yield(.stopped)
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
		}
	}

	func stop() {
		task?.cancel()
		task = nil
	}

	// MARK: - Demux loop
	private nonisolated func demuxLoop(
		url: URL,
		emit: @escaping @Sendable (RTSPEvent) -> Void
	) throws {
		try validateScheme(url)
		// Watchdog: `stimeout` covers socket-level RCVTIMEO during the initial
		// connect, but a camera that vanishes mid-stream (TCP stall with no
		// FIN/RST) can still leave `av_read_frame` blocked indefinitely.
		// FFmpeg checks `interrupt_callback` at every internal I/O sync point —
		// when too much time has passed without a successful packet, we
		// signal abort and the read returns `AVERROR_EXIT`.
		let watchdog = DemuxWatchdog(timeout: 5.0)
		var formatCtx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
		installInterruptCallback(on: formatCtx, watchdog: watchdog)

		var opts: OpaquePointer?
		configureRTSPOptions(&opts)
		defer { av_dict_free(&opts) }
		guard avformat_open_input(&formatCtx, url.absoluteString, nil, &opts) == 0 else {
			throw NSError(
				domain: "RTSP",
				code: -1,
				userInfo: [NSLocalizedDescriptionKey: String(localized: "error.cannotOpenURL", bundle: .module)]
			)
		}
		defer { avformat_close_input(&formatCtx) }
		guard avformat_find_stream_info(formatCtx, nil) >= 0 else {
			throw NSError(
				domain: "RTSP",
				code: -2,
				userInfo: [NSLocalizedDescriptionKey: String(localized: "error.cannotFindStreamInfo", bundle: .module)]
			)
		}
		guard let stream = findH264Stream(formatCtx: formatCtx!) else {
			throw NSError(
				domain: "RTSP",
				code: -3,
				userInfo: [NSLocalizedDescriptionKey: String(localized: "error.noH264Stream", bundle: .module)]
			)
		}
		if let paramsSet = extractParameterSets(formatCtx: formatCtx!, streamIndex: stream.index) {
			emit(.format(paramsSet))
		}
		var pkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
		defer { av_packet_free(&pkt) }
		// Reset the watchdog: open + find_stream_info eat into the budget,
		// but the read loop deserves its own fresh window.
		watchdog.lastActivity = CFAbsoluteTimeGetCurrent()
		runReadLoop(
			formatCtx: formatCtx,
			pkt: pkt,
			stream: stream,
			watchdog: watchdog,
			emit: emit
		)
	}

	// Restrict to RTSP(S) URLs to prevent FFmpeg from opening file://, pipe:, http://, etc.
	private nonisolated func validateScheme(_ url: URL) throws {
		guard let scheme = url.scheme?.lowercased(), scheme == "rtsp" || scheme == "rtsps" else {
			throw NSError(
				domain: "RTSP",
				code: -4,
				userInfo: [
					NSLocalizedDescriptionKey: String(localized: "error.unsupportedScheme", bundle: .module)
				]
			)
		}
	}

	private nonisolated func configureRTSPOptions(_ opts: inout OpaquePointer?) {
		av_dict_set(&opts, "fflags", "nobuffer+discardcorrupt", 0)
		av_dict_set(&opts, "flags", "low_delay", 0)
		av_dict_set(&opts, "max_delay", "200000", 0)
		av_dict_set(&opts, "stimeout", "5000000", 0)
		// Force TCP for RTP/RTCP transport. UDP is the FFmpeg default but is
		// vulnerable to off-path RTP injection (no handshake, payloads accepted
		// from any source that guesses the SSRC), and it loses NAT traversal
		// reliability. TCP-interleaved RTSP rides the same socket as the
		// control channel — no third-party can inject frames.
		av_dict_set(&opts, "rtsp_transport", "tcp", 0)
		// Defense-in-depth: restrict FFmpeg's nested protocol resolution to RTSP and its transports.
		av_dict_set(&opts, "protocol_whitelist", "rtsp,rtsps,rtp,udp,tcp,tls", 0)
		// FFmpeg's default for tls_verify is 0 in many builds, which silently
		// accepts any server certificate on rtsps:// — opt in explicitly so
		// the encrypted transport actually authenticates the peer.
		av_dict_set(&opts, "tls_verify", "1", 0)
	}

	private nonisolated func findH264Stream(
		formatCtx: UnsafeMutablePointer<AVFormatContext>
	) -> (index: Int32, timeBase: AVRational)? {
		let nbStreams = Int(formatCtx.pointee.nb_streams)
		for idxStream in 0..<nbStreams {
			let stream = formatCtx.pointee.streams[idxStream]!
			if stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_H264 {
				return (Int32(idxStream), stream.pointee.time_base)
			}
		}
		return nil
	}

	private nonisolated func runReadLoop(
		formatCtx: UnsafeMutablePointer<AVFormatContext>?,
		pkt: UnsafeMutablePointer<AVPacket>?,
		stream: (index: Int32, timeBase: AVRational),
		watchdog: DemuxWatchdog,
		emit: (RTSPEvent) -> Void
	) {
		// AVERROR_EXIT is returned when our interrupt_callback aborted the
		// blocked read (stale connection or task cancellation). Either way,
		// surface as end-of-stream so the caller can drive reconnection.
		let terminalCodes: Set<Int32> = [AVERROR_EOF, AVERROR_EXIT]
		while !Task.isCancelled {
			let ret = av_read_frame(formatCtx, pkt)
			if terminalCodes.contains(ret) {
				break
			}
			guard ret >= 0 else {
				av_packet_unref(pkt)
				continue
			}
			defer { av_packet_unref(pkt) }
			watchdog.lastActivity = CFAbsoluteTimeGetCurrent()
			processPacket(pkt!, videoStreamIndex: stream.index, timeBase: stream.timeBase, emit: emit)
		}
	}

	// Wires our watchdog into FFmpeg's `interrupt_callback` slot. The callback
	// is `@convention(c)` so it can't capture context — the watchdog reaches
	// it via `Unmanaged.fromOpaque(opaque)` on the void* refcon we install.
	private nonisolated func installInterruptCallback(
		on formatCtx: UnsafeMutablePointer<AVFormatContext>?,
		watchdog: DemuxWatchdog
	) {
		formatCtx?.pointee.interrupt_callback.opaque = Unmanaged.passUnretained(watchdog).toOpaque()
		formatCtx?.pointee.interrupt_callback.callback = { opaque in
			guard let opaque else { return 0 }
			let state = Unmanaged<DemuxWatchdog>.fromOpaque(opaque).takeUnretainedValue()
			if Task.isCancelled { return 1 }
			if CFAbsoluteTimeGetCurrent() - state.lastActivity > state.timeout { return 1 }
			return 0
		}
	}

	// Extracted from `demuxLoop` to keep that function below the project's
	// cyclomatic-complexity ceiling. Per-packet validation and conversion lives
	// here; the loop only handles I/O orchestration.
	private nonisolated func processPacket(
		_ pkt: UnsafeMutablePointer<AVPacket>,
		videoStreamIndex: Int32,
		timeBase: AVRational,
		emit: (RTSPEvent) -> Void
	) {
		guard pkt.pointee.stream_index == videoStreamIndex else { return }
		// A malformed stream can deliver an empty, null-data, or oversized packet.
		// FFmpeg's internal limits are generous, so refuse anything pathological
		// (>16 MB) ourselves before handing the buffer to `Data(bytes:count:)`.
		guard let payload = pkt.pointee.data,
					(1...16 * 1024 * 1024).contains(pkt.pointee.size) else { return }
		let pts = makeCMTime(pts: pkt.pointee.pts, timeBase: timeBase)
		let dts = makeCMTime(pts: pkt.pointee.dts, timeBase: timeBase)
		var data = Data(bytes: payload, count: Int(pkt.pointee.size))
		// Annex-B -> AVCC if needed
		if data.starts(with: [0, 0, 0, 1]) || data.starts(with: [0, 0, 1]) {
			data = annexBtoAVCC(data)
		}
		emit(.frame(VideoFrame(data: data, pts: pts, dts: dts)))
	}
	// MARK: - SPS/PPS
	private nonisolated func extractParameterSets(
		formatCtx: UnsafeMutablePointer<AVFormatContext>,
		streamIndex: Int32
	) -> ParameterSet? {
		guard let stream = formatCtx.pointee.streams[Int(streamIndex)],
					let extradata = stream.pointee.codecpar.pointee.extradata
		else { return nil }
		let size = Int(stream.pointee.codecpar.pointee.extradata_size)
		guard size > 4 else { return nil }
		let data = Data(bytes: extradata, count: size)

		if let parameterSets = extractParameterSetsFromAVCC(data) {
			return parameterSets
		}

		let nalus = annexBNALURanges(in: data).map { Data(data[$0]) }
		// Don't subscript blindly: a malformed stream (e.g. consecutive start
		// codes) could otherwise feed a zero-length NALU slice into `$0[0]`.
		guard
			let sps = nalus.first(where: { $0.first.map { $0 & 0x1F == 7 } ?? false }),
			let pps = nalus.first(where: { $0.first.map { $0 & 0x1F == 8 } ?? false })
		else { return nil }
		return ParameterSet(sps: sps, pps: pps, nalUnitHeaderLength: 4)
	}

	// MARK: - Helpers
	private nonisolated func makeCMTime(pts: Int64, timeBase: AVRational) -> CMTime {
		// FFmpeg's AV_NOPTS_VALUE is INT64_MIN — i.e. Swift's `Int64.min`.
		guard pts != .min else { return .invalid }
		// CMTimeScale must be a positive Int32. A malformed stream advertising
		// a zero or negative denominator would otherwise produce a CMTime that
		// CoreMedia treats as invalid downstream — be explicit instead.
		guard timeBase.den > 0 else { return .invalid }
		// `pts * timeBase.num` is a routine FFmpeg multiplication that can wrap on
		// long-running streams or pathological time bases. Detect overflow
		// rather than silently emit a junk timestamp.
		let (value, overflow) = pts.multipliedReportingOverflow(by: Int64(timeBase.num))
		guard !overflow else { return .invalid }
		return CMTimeMake(value: value, timescale: timeBase.den)
	}

}

func annexBtoAVCC(_ data: Data) -> Data {
	var result = Data()
	let ranges = annexBNALURanges(in: data)

	for range in ranges {
		// Replace start code with 4-byte big-endian length
		let naluLen = range.count
		var length = UInt32(naluLen).bigEndian
		result.append(Data(bytes: &length, count: 4))
		result.append(Data(data[range]))
	}

	return result.isEmpty ? data : result  // passthrough if no start codes found
}

// `internal` rather than `private` so the parser can be exercised from the
// test target — it handles attacker-controlled bytes from extradata, so its
// boundary checks are security-critical and must stay covered.
func extractParameterSetsFromAVCC(_ data: Data) -> ParameterSet? {
	guard data.count > 7, data[data.startIndex] == 1 else { return nil }

	// `& 0x03` constrains this to 1...4 — the decoder's `filterNALUs` and
	// `appendNALULength` rely on that range for their length-prefix arithmetic.
	let nalUnitHeaderLength = Int(data[data.startIndex + 4] & 0x03) + 1
	var offset = data.startIndex + 5
	let spsCount = Int(data[offset] & 0x1F)
	offset += 1

	var sps: Data?
	for _ in 0..<spsCount {
		guard offset + 2 <= data.endIndex else { return nil }
		let size = Int(data[offset]) << 8 | Int(data[offset + 1])
		offset += 2
		guard size > 0, offset + size <= data.endIndex else { return nil }
		sps = Data(data[offset..<offset + size])
		offset += size
	}

	guard offset < data.endIndex else { return nil }
	let ppsCount = Int(data[offset])
	offset += 1

	var pps: Data?
	for _ in 0..<ppsCount {
		guard offset + 2 <= data.endIndex else { return nil }
		let size = Int(data[offset]) << 8 | Int(data[offset + 1])
		offset += 2
		guard size > 0, offset + size <= data.endIndex else { return nil }
		pps = Data(data[offset..<offset + size])
		offset += size
	}

	guard let sps, let pps else { return nil }
	return ParameterSet(sps: sps, pps: pps, nalUnitHeaderLength: nalUnitHeaderLength)
}

// Internal for testability — see note on `extractParameterSetsFromAVCC`.
func annexBNALURanges(in data: Data) -> [Range<Data.Index>] {
	var starts: [(startCode: Range<Data.Index>, naluStart: Data.Index)] = []
	var index = data.startIndex

	while index < data.endIndex {
		if index + 4 <= data.endIndex,
			 data[index] == 0,
			 data[index + 1] == 0,
			 data[index + 2] == 0,
			 data[index + 3] == 1 {
			let startCode = index..<index + 4
			starts.append((startCode, startCode.upperBound))
			index = startCode.upperBound
		} else if index + 3 <= data.endIndex,
							data[index] == 0,
							data[index + 1] == 0,
							data[index + 2] == 1 {
			let startCode = index..<index + 3
			starts.append((startCode, startCode.upperBound))
			index = startCode.upperBound
		} else {
			index += 1
		}
	}

	return starts.enumerated().compactMap { offset, start in
		let end = offset + 1 < starts.count ? starts[offset + 1].startCode.lowerBound : data.endIndex
		return start.naluStart < end ? start.naluStart..<end : nil
	}
}

let AVERROR_EOF: Int32 = -541478725
// FFERRTAG('E','X','I','T') — returned by FFmpeg I/O when our `interrupt_callback`
// asked it to abort a blocking operation.
let AVERROR_EXIT: Int32 = -1414092869

// Reference type so the demuxer's `interrupt_callback` (a C function pointer that
// can't capture) can read the timestamp via `Unmanaged.fromOpaque`. Holds the
// shared watchdog state for the lifetime of one demux loop.
final class DemuxWatchdog {
	var lastActivity: TimeInterval
	let timeout: TimeInterval
	init(timeout: TimeInterval) {
		self.timeout = timeout
		self.lastActivity = CFAbsoluteTimeGetCurrent()
	}
}

//
//  RTSPStreamSource.swift
//  SwiftRTSPPlayer
//

import Foundation
import os

private let log = Logger(subsystem: "SwiftRTSPPlayer", category: "RTSPStreamSource")

/// Keeps one camera playing: connects, reports its state, hands over decoded
/// pictures, and reconnects on its own when the stream drops.
///
/// It needs no view, so the same stream can feed a display, an offscreen
/// composition, or both:
///
/// ```swift
/// let source = RTSPStreamSource(url: url)
/// for await event in await source.events() {
///     if case .picture(let frame) = event { latest = frame }
/// }
/// ```
public actor RTSPStreamSource {

	public enum Event: Sendable {
		case state(RTSPPlaybackState)
		case picture(DecodedFrame)
	}

	/// Surveillance cameras can be away for arbitrary stretches (a network
	/// reboot, a power blip), so retry steadily rather than backing off.
	public static let defaultReconnectDelay: TimeInterval = 5.0

	private let url: URL
	private let reconnectDelay: TimeInterval
	private var task: Task<Void, Never>?
	private var pipeline: RTSPPipeline?

	public init(url: URL, reconnectDelay: TimeInterval = RTSPStreamSource.defaultReconnectDelay) {
		self.url = url
		self.reconnectDelay = reconnectDelay
	}

	/// Starts the stream and reports what happens to it. Ending the iteration —
	/// or calling `stop()` — tears the connection down.
	public func events() -> AsyncStream<Event> {
		let (stream, continuation) = AsyncStream<Event>.makeStream()
		task?.cancel()
		task = Task { [weak self] in
			await self?.run(yielding: continuation)
		}
		continuation.onTermination = { [weak self] _ in
			Task { await self?.stop() }
		}
		return stream
	}

	public func stop() {
		task?.cancel()
		task = nil
		let stopped = pipeline
		pipeline = nil
		Task { await stopped?.stop() }
	}

	private func run(yielding continuation: AsyncStream<Event>.Continuation) async {
		while !Task.isCancelled {
			continuation.yield(.state(.connecting))
			await playOnce(yielding: continuation)

			guard !Task.isCancelled else { break }
			// Light jitter so several cameras don't reconnect in lockstep after
			// the same network event.
			let jitter = Double.random(in: 0.85...1.15)
			try? await Task.sleep(for: .seconds(reconnectDelay * jitter))
		}
		continuation.yield(.state(.stopped))
		continuation.finish()
	}

	/// One connection, from the first picture to the end of the stream.
	private func playOnce(yielding continuation: AsyncStream<Event>.Continuation) async {
		let pipeline = RTSPPipeline()
		self.pipeline = pipeline
		var sawPicture = false

		do {
			for try await frame in await pipeline.frames(url: url) {
				if Task.isCancelled { break }
				if !sawPicture {
					sawPicture = true
					continuation.yield(.state(.playing))
				}
				continuation.yield(.picture(frame))
			}
		} catch {
			log.error("RTSP stream error: \(redactCredentials(in: error.localizedDescription), privacy: .public)")
		}

		await pipeline.stop()
		if self.pipeline === pipeline {
			self.pipeline = nil
		}
	}
}

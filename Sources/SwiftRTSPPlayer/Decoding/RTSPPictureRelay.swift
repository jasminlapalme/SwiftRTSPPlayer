//
//  RTSPPictureRelay.swift
//  SwiftRTSPPlayer
//

import Foundation
import Synchronization

/// Receives decoded pictures for analysis, off the main actor.
public typealias RTSPPictureHandler = @concurrent @Sendable (DecodedFrame) async -> Void

/// Hands pictures to a consumer slower than the camera: only the newest waits,
/// so an analysis never falls behind the stream.
final class RTSPPictureRelay: Sendable {

	private struct Configuration {
		var handler: RTSPPictureHandler
		var minimumInterval: Duration
	}

	/// Shared with the delivery task, which must not keep the relay itself alive.
	private final class Shared: Sendable {
		let configuration: Mutex<Configuration>

		init(_ configuration: Configuration) {
			self.configuration = Mutex(configuration)
		}
	}

	private let shared: Shared
	private let continuation: AsyncStream<DecodedFrame>.Continuation
	private let task: Task<Void, Never>

	init(minimumInterval: Duration = .zero, handler: @escaping RTSPPictureHandler) {
		let shared = Shared(Configuration(handler: handler, minimumInterval: minimumInterval))
		let (stream, continuation) = AsyncStream<DecodedFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
		self.shared = shared
		self.continuation = continuation
		task = Task.detached {
			let clock = ContinuousClock()
			for await frame in stream {
				let start = clock.now
				let configuration = shared.configuration.withLock { $0 }
				await configuration.handler(frame)
				try? await clock.sleep(until: start + configuration.minimumInterval)
			}
		}
	}

	deinit {
		continuation.finish()
		task.cancel()
	}

	/// Swaps the handler without dropping the picture being analysed.
	func update(minimumInterval: Duration, handler: @escaping RTSPPictureHandler) {
		shared.configuration.withLock {
			$0 = Configuration(handler: handler, minimumInterval: minimumInterval)
		}
	}

	func send(_ frame: DecodedFrame) {
		continuation.yield(frame)
	}
}

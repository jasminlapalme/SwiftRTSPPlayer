import Foundation
import Testing
@testable import SwiftRTSPPlayer

// MARK: - Keeping a camera playing

/// The connect / reconnect loop used to live inside a view, where none of this
/// could be checked. Port 1 refuses connections at once, so an unreachable
/// camera is cheap to simulate.
@Suite("RTSPStreamSource")
struct StreamSourceTests {

	private var unreachable: URL {
		URL(string: "rtsp://127.0.0.1:1/nothing")!
	}

	@Test("An unreachable camera is retried rather than given up on", .timeLimit(.minutes(1)))
	func retriesWhileUnreachable() async throws {
		let source = RTSPStreamSource(url: unreachable, reconnectDelay: 0.05)
		var attempts = 0

		for await event in await source.events() {
			if case .state(.connecting) = event {
				attempts += 1
				if attempts >= 3 { break }
			}
		}
		await source.stop()

		#expect(attempts >= 3)
	}

	@Test("An unreachable camera never claims to be playing", .timeLimit(.minutes(1)))
	func neverReportsPlaying() async throws {
		let source = RTSPStreamSource(url: unreachable, reconnectDelay: 0.05)
		var states: [RTSPPlaybackState] = []

		for await event in await source.events() {
			if case .state(let state) = event {
				states.append(state)
				if states.count >= 3 { break }
			}
		}
		await source.stop()

		#expect(!states.contains(.playing))
		#expect(states.allSatisfy { $0 == .connecting })
	}

	@Test("Stopping ends the stream", .timeLimit(.minutes(1)))
	func stoppingEndsTheStream() async throws {
		let source = RTSPStreamSource(url: unreachable, reconnectDelay: 0.05)
		let events = await source.events()

		// Let it reach its first attempt, then pull the rug.
		var iterator = events.makeAsyncIterator()
		_ = await iterator.next()
		await source.stop()

		// The stream must finish rather than hang; the last word is `stopped`.
		var last: RTSPPlaybackState?
		while let event = await iterator.next() {
			if case .state(let state) = event { last = state }
		}
		#expect(last == .stopped)
	}
}

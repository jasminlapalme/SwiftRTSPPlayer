import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import SwiftRTSPPlayer

// MARK: - Handing pictures to an analysis

@Suite("RTSPPictureRelay")
struct PictureRelayTests {

	/// Pictures are told apart by their timestamp; the pixels don't matter here.
	private func makeFrame(_ index: Int64) throws -> DecodedFrame {
		var buffer: CVPixelBuffer?
		CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
		return DecodedFrame(pixelBuffer: try #require(buffer), pts: CMTime(value: index, timescale: 1))
	}

	private actor Recorder {
		private(set) var indices: [Int64] = []
		private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

		func record(_ frame: DecodedFrame) {
			indices.append(frame.pts.value)
			waiters.removeAll { waiter in
				guard indices.count >= waiter.count else { return false }
				waiter.continuation.resume()
				return true
			}
		}

		func waitFor(count: Int) async {
			guard indices.count < count else { return }
			await withCheckedContinuation { waiters.append((count, $0)) }
		}
	}

	/// Holds a handler back until the test lets it go.
	private actor Gate {
		private var isOpen = false
		private var waiters: [CheckedContinuation<Void, Never>] = []

		func pass() async {
			guard !isOpen else { return }
			await withCheckedContinuation { waiters.append($0) }
		}

		func open() {
			isOpen = true
			waiters.forEach { $0.resume() }
			waiters.removeAll()
		}
	}

	@Test("Every picture reaches a handler that keeps up", .timeLimit(.minutes(1)))
	func deliversPictures() async throws {
		let recorder = Recorder()
		let relay = RTSPPictureRelay { await recorder.record($0) }

		for index in 1...3 {
			relay.send(try makeFrame(Int64(index)))
			await recorder.waitFor(count: index)
		}

		#expect(await recorder.indices == [1, 2, 3])
	}

	@Test("A slow handler skips to the newest picture", .timeLimit(.minutes(1)))
	func skipsToNewest() async throws {
		let recorder = Recorder()
		let gate = Gate()
		let started = Recorder()
		let relay = RTSPPictureRelay { frame in
			await started.record(frame)
			await gate.pass()
			await recorder.record(frame)
		}

		relay.send(try makeFrame(1))
		await started.waitFor(count: 1)
		for index in 2...5 {
			relay.send(try makeFrame(Int64(index)))
		}
		await gate.open()
		await recorder.waitFor(count: 2)

		#expect(await recorder.indices == [1, 5])
	}

	@Test("The minimum interval spaces the calls out", .timeLimit(.minutes(1)))
	func respectsMinimumInterval() async throws {
		let recorder = Recorder()
		let relay = RTSPPictureRelay(minimumInterval: .milliseconds(300)) { await recorder.record($0) }
		let clock = ContinuousClock()

		let start = clock.now
		relay.send(try makeFrame(1))
		await recorder.waitFor(count: 1)
		relay.send(try makeFrame(2))
		await recorder.waitFor(count: 2)

		#expect(clock.now - start >= .milliseconds(250))
	}

	@Test("A new handler takes over without a gap", .timeLimit(.minutes(1)))
	func swapsHandler() async throws {
		let first = Recorder()
		let second = Recorder()
		let relay = RTSPPictureRelay { await first.record($0) }

		relay.send(try makeFrame(1))
		await first.waitFor(count: 1)
		relay.update(minimumInterval: .zero) { await second.record($0) }
		relay.send(try makeFrame(2))
		await second.waitFor(count: 1)

		#expect(await first.indices == [1])
		#expect(await second.indices == [2])
	}

	@MainActor
	@Test("A handler written on the main actor runs off it", .timeLimit(.minutes(1)))
	func handlerLeavesMainActor() async throws {
		let recorder = Recorder()
		let onMainThread = Recorder()
		let relay = RTSPPictureRelay { frame in
			if pthread_main_np() != 0 { await onMainThread.record(frame) }
			await recorder.record(frame)
		}

		relay.send(try makeFrame(1))
		await recorder.waitFor(count: 1)

		#expect(await onMainThread.indices.isEmpty)
	}
}

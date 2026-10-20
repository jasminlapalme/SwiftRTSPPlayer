//
//  MotionMeter.swift
//  DemoSwiftRTSPPlayer
//

import CoreVideo
import Observation
import Synchronization
import SwiftRTSPPlayer
import SwiftUI

/// Measures how much of the picture moves, to show what `onPicture` hands an app.
@Observable
final class MotionMeter {
	/// The share of the picture that changed since the previous analysis, 0 to 1.
	private(set) var level: Double?
	private(set) var duration: Duration?

	private nonisolated static let gridWidth = 64
	private nonisolated static let gridHeight = 36
	/// Luma steps a sample must move by to count: compression noise stays below it.
	private nonisolated static let threshold = 25

	private nonisolated let previous = Mutex<[UInt8]?>(nil)

	/// Runs off the main actor, on the picture as the camera sends it.
	@concurrent nonisolated func analyze(_ frame: DecodedFrame) async {
		let clock = ContinuousClock()
		let start = clock.now
		guard let samples = Self.lumaSamples(of: frame.pixelBuffer) else { return }
		let moving = previous.withLock { previous -> Double? in
			defer { previous = samples }
			guard let previous, previous.count == samples.count else { return nil }
			let changed = zip(previous, samples).count { abs(Int($0) - Int($1)) > Self.threshold }
			return Double(changed) / Double(samples.count)
		}
		guard let moving else { return }
		await update(level: moving, duration: clock.now - start)
	}

	private func update(level: Double, duration: Duration) {
		self.level = level
		self.duration = duration
	}

	/// A coarse grid read straight from the luma plane: enough to see motion, cheap to compare.
	private nonisolated static func lumaSamples(of buffer: CVPixelBuffer) -> [UInt8]? {
		CVPixelBufferLockBaseAddress(buffer, .readOnly)
		defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
		guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
		let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
		let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
		let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
		let luma = base.assumingMemoryBound(to: UInt8.self)

		var samples: [UInt8] = []
		samples.reserveCapacity(gridWidth * gridHeight)
		for row in 0..<gridHeight {
			let lumaRow = (2 * row + 1) * height / (2 * gridHeight)
			for column in 0..<gridWidth {
				let lumaColumn = (2 * column + 1) * width / (2 * gridWidth)
				samples.append(luma[lumaRow * bytesPerRow + lumaColumn])
			}
		}
		return samples
	}
}

/// The analysis result, laid over the video.
struct MotionBadge: View {
	let meter: MotionMeter

	var body: some View {
		if let level = meter.level, let duration = meter.duration {
			let percent = level.formatted(.percent.precision(.fractionLength(0)))
			Label {
				Text("Motion \(percent) · \(duration.formatted(.units(allowed: [.milliseconds])))")
			} icon: {
				Image(systemName: "figure.walk.motion")
			}
			.font(.callout.monospacedDigit())
			.padding(.horizontal, 10)
			.padding(.vertical, 6)
			.background(.thinMaterial, in: Capsule())
		}
	}
}

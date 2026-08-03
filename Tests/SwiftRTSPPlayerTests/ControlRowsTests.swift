import Foundation
import SwiftUI
import Testing
#if os(macOS)
import AppKit
#endif
@testable import SwiftRTSPPlayer

// MARK: - tickValues

@Suite("tickValues")
struct TickValuesTests {

	@Test("Quarter turns of the default rotation range")
	func defaultRotationRange() {
		#expect(tickValues(in: -180...180, spacing: rotationTickSpacing) == [-180, -90, 0, 90, 180])
	}

	@Test("Only the multiples inside the range")
	func partialRange() {
		#expect(tickValues(in: -100...200, spacing: 90) == [-90, 0, 90, 180])
	}

	@Test("A range with no multiple inside yields none")
	func noMultiple() {
		#expect(tickValues(in: 10...80, spacing: 90).isEmpty)
	}

	@Test("A non-positive spacing yields none")
	func nonPositiveSpacing() {
		#expect(tickValues(in: -180...180, spacing: 0).isEmpty)
	}
}

#if os(macOS)

// MARK: - TickedSlider snapping

@Suite("TickedSlider snapping")
@MainActor
struct TickedSliderSnappingTests {

	/// A slider 360 pt wide over -180...180, so one point is one degree and the
	/// 6 pt snap distance is 6°.
	private func makeSlider(tickMarks: Int) -> NSSlider {
		let slider = NSSlider(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
		slider.minValue = -180
		slider.maxValue = 180
		slider.numberOfTickMarks = tickMarks
		slider.allowsTickMarkValuesOnly = false
		return slider
	}

	/// Drives the slider the way AppKit does while dragging: set the value, then
	/// fire the coordinator's action. Returns what the binding received.
	private func drag(to position: Double, tickMarks: Int = 5) -> CGFloat {
		nonisolated(unsafe) var received: CGFloat = .nan
		let binding = Binding<CGFloat>(get: { received }, set: { received = $0 })
		let coordinator = TickedSlider.Coordinator(value: binding)
		let slider = makeSlider(tickMarks: tickMarks)
		slider.doubleValue = position
		coordinator.sliderChanged(slider)
		return received
	}

	@Test("Lands on the tick when dropped just short of it")
	func snapsFromBelow() {
		#expect(drag(to: 87) == 90)
	}

	@Test("Lands on the tick when dropped just past it")
	func snapsFromAbove() {
		#expect(drag(to: 93) == 90)
	}

	@Test("Snaps to zero, the mark in the middle")
	func snapsToZero() {
		#expect(drag(to: -3) == 0)
	}

	@Test("Keeps the exact value outside the snap distance")
	func keepsValueOutsideTolerance() {
		#expect(drag(to: 80) == 80)
	}

	@Test("A row without tick marks never snaps")
	func noTickMarksNoSnapping() {
		#expect(drag(to: 87, tickMarks: 0) == 87)
	}
}

#endif

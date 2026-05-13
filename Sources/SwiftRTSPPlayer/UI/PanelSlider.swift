//
//  PanelSlider.swift
//  SwiftRTSPPlayer
//

import SwiftUI

/// Custom slider styled to match the transform panel. Drag adjusts by delta —
/// scaled by `sensitivity` so "Fine" mode shrinks the per-pixel value change.
struct PanelSlider: View {
	@Binding var value: CGFloat
	let range: ClosedRange<CGFloat>
	let sensitivity: CGFloat
	let isSelected: Bool
	let ticks: [CGFloat]
	let onInteract: () -> Void

	@State private var dragStartValue: CGFloat?

	init(
		value: Binding<CGFloat>,
		range: ClosedRange<CGFloat>,
		sensitivity: CGFloat,
		isSelected: Bool,
		ticks: [CGFloat] = [],
		onInteract: @escaping () -> Void
	) {
		self._value = value
		self.range = range
		self.sensitivity = sensitivity
		self.isSelected = isSelected
		self.ticks = ticks
		self.onInteract = onInteract
	}

	var body: some View {
		GeometryReader { geo in
			let width = max(1, geo.size.width)
			let span = range.upperBound - range.lowerBound
			let clamped = min(max(value, range.lowerBound), range.upperBound)
			let progress = span > 0 ? (clamped - range.lowerBound) / span : 0
			let thumbSize: CGFloat = 16
			let trackHeight: CGFloat = 4
			let tickHeight: CGFloat = 10
			let thumbX = progress * width

			ZStack(alignment: .leading) {
				Capsule()
					.fill(Color.primary.opacity(0.15))
					.frame(height: trackHeight)

				ForEach(ticks, id: \.self) { tickValue in
					let tickProgress = span > 0 ? (tickValue - range.lowerBound) / span : 0
					Rectangle()
						.fill(Color.primary.opacity(0.45))
						.frame(width: 1.5, height: tickHeight)
						.offset(x: tickProgress * width - 0.75)
				}

				Capsule()
					.fill(Color.panelAccent)
					.frame(width: max(0, thumbX), height: trackHeight)

				Circle()
					.fill(Color.primary)
					.frame(width: thumbSize, height: thumbSize)
					.shadow(color: .secondary.opacity(0.35), radius: 2, y: 1)
					.offset(x: thumbX - thumbSize / 2)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.contentShape(Rectangle())
			#if !os(tvOS)
			// tvOS has no DragGesture — value adjustment there is driven by
			// the row's `onMoveCommand` instead (Siri remote left/right).
			.gesture(
				DragGesture(minimumDistance: 0)
					.onChanged { drag in
						onInteract()
						if dragStartValue == nil {
							dragStartValue = clamped
						}
						let start = dragStartValue ?? clamped
						let delta = (drag.translation.width / width) * span * sensitivity
						let next = start + delta
						let bounded = min(max(next, range.lowerBound), range.upperBound)
						value = snapped(bounded)
					}
					.onEnded { _ in
						dragStartValue = nil
					}
			)
			#endif
		}
	}

	/// When ticks are defined and we're not in fine mode (sensitivity == 1.0),
	/// snap to the nearest tick. Otherwise return the value unchanged.
	private func snapped(_ raw: CGFloat) -> CGFloat {
		guard !ticks.isEmpty, sensitivity >= 1.0 else { return raw }
		return ticks.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? raw
	}
}

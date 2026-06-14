//
//  RTSPTransformControlPanel+Row.swift
//  SwiftRTSPPlayer
//

import SwiftUI

extension RTSPTransformControlPanel {

	@ViewBuilder
	func row(
		field: Field,
		label: String,
		value: Binding<CGFloat>,
		range: ClosedRange<CGFloat>,
		sensivity: CGFloat,
		ticks: [CGFloat] = []
	) -> some View {
		let isSelected = isFieldSelected(field)
		HStack(spacing: 14) {
			Text(label)
				.font(.subheadline)
				.foregroundStyle(isSelected ? Color.panelAccent : .primary.opacity(0.85))
				.frame(alignment: .leading)

			VStack(spacing: 2) {
				PanelSlider(
					value: value,
					range: range,
					sensitivity: isFineMode ? sensivity / 5.0 : sensivity,
					isSelected: isSelected,
					ticks: ticks,
					onInteract: {
#if !os(tvOS)
						selectedField = field
#endif
					}
				)
				.frame(height: 24)
			}
		}
		.padding()
		#if os(tvOS)
		.background(
			RoundedRectangle(cornerRadius: 10, style: .continuous)
				.fill(isSelected ? Color.panelAccent.opacity(0.12) : .clear)
		)
		.overlay(
			RoundedRectangle(cornerRadius: 10, style: .continuous)
				.stroke(isSelected ? Color.panelAccent.opacity(0.85) : .clear, lineWidth: 1.5)
		)
		.focusable()
		// On tvOS the Siri remote's clickpad reports left/right presses as
		// move commands — discrete fallback for the touchpad swipe.
		.onMoveCommand { direction in
			applyMoveCommand(direction, value: value, range: range, sensivity: sensivity, ticks: ticks)
		}
		#else
		.onTapGesture { selectedField = field }
		#endif
		.contentShape(Rectangle())
		.focused($focusedField, equals: field)
		.animation(.easeInOut(duration: 0.18), value: isSelected)
	}

	func isFieldSelected(_ field: Field) -> Bool {
#if os(tvOS)
		return focusedField == field
#else
		return selectedField == field
#endif
	}

#if os(tvOS)
	func applyMoveCommand(
		_ direction: MoveCommandDirection,
		value: Binding<CGFloat>,
		range: ClosedRange<CGFloat>,
		sensivity: CGFloat,
		ticks: [CGFloat]
	) {
		let useTicks = !isFineMode && !ticks.isEmpty
		let step = isFineMode ? sensivity / 5.0 : sensivity
		switch direction {
		case .left:
			if useTicks, let prev = ticks.filter({ $0 < value.wrappedValue }).max() {
				value.wrappedValue = prev
			} else {
				value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
			}
		case .right:
			if useTicks, let next = ticks.filter({ $0 > value.wrappedValue }).min() {
				value.wrappedValue = next
			} else {
				value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
			}
		default:
			break
		}
	}
#endif
}

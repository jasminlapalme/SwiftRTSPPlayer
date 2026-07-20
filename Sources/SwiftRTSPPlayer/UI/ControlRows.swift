//
//  ControlRows.swift
//  SwiftRTSPPlayer
//

import SwiftUI

#if os(tvOS)

/// One labelled slider row of the tvOS control panel. The row is focusable and
/// the Siri remote's clickpad left/right presses adjust the value; the swipe
/// gesture is handled by `PanelSlider`. "Fine" mode divides the step by 5 and
/// disables tick snapping.
struct TVSliderRow<Field: Hashable>: View {
	let field: Field
	let label: String
	@Binding var value: CGFloat
	let range: ClosedRange<CGFloat>
	let sensivity: CGFloat
	var ticks: [CGFloat] = []
	let isFineMode: Bool
	let focusedField: FocusState<Field?>.Binding

	private var isSelected: Bool { focusedField.wrappedValue == field }

	var body: some View {
		HStack(spacing: 14) {
			Text(label)
				.font(.subheadline)
				.foregroundStyle(isSelected ? Color.panelAccent : .primary.opacity(0.85))
				.frame(alignment: .leading)

			PanelSlider(
				value: $value,
				range: range,
				sensitivity: isFineMode ? sensivity / 5.0 : sensivity,
				isSelected: isSelected,
				ticks: ticks,
				onInteract: {}
			)
			.frame(height: 24)
		}
		.padding()
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
		.onMoveCommand(perform: applyMoveCommand)
		.contentShape(Rectangle())
		.focused(focusedField, equals: field)
		.animation(.easeInOut(duration: 0.18), value: isSelected)
	}

	private func applyMoveCommand(_ direction: MoveCommandDirection) {
		let useTicks = !isFineMode && !ticks.isEmpty
		let step = isFineMode ? sensivity / 5.0 : sensivity
		switch direction {
		case .left:
			if useTicks, let prev = ticks.filter({ $0 < value }).max() {
				value = prev
			} else {
				value = max(range.lowerBound, value - step)
			}
		case .right:
			if useTicks, let next = ticks.filter({ $0 > value }).min() {
				value = next
			} else {
				value = min(range.upperBound, value + step)
			}
		default:
			break
		}
	}
}

#else

/// One labelled row of the iOS/macOS control panel: a native slider plus a
/// numeric field for exact values. Built as a `GridRow` so labels, sliders and
/// fields align across the rows of the enclosing `Grid`.
@MainActor @ViewBuilder
func nativeSliderRow(
	label: String,
	value: Binding<CGFloat>,
	range: ClosedRange<CGFloat>
) -> some View {
	GridRow {
		Text(label)
			.gridColumnAlignment(.leading)

		Slider(value: value, in: range)

		TextField(
			label,
			value: Binding(
				get: { Double(value.wrappedValue) },
				set: { value.wrappedValue = min(max(CGFloat($0), range.lowerBound), range.upperBound) }
			),
			format: .number.precision(.fractionLength(0...2))
		)
		.labelsHidden()
		.textFieldStyle(.roundedBorder)
		.multilineTextAlignment(.trailing)
		.frame(width: 84)
#if os(iOS) || os(visionOS)
		.keyboardType(.numbersAndPunctuation)
#endif
	}
}

#endif

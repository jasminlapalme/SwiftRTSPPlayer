//
//  ControlRows.swift
//  SwiftRTSPPlayer
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// How much smaller one fine adjustment is than the row's base sensitivity.
/// Shared by the tvOS "fine" mode and the macOS steppers so both platforms nudge
/// a value by the same amount.
let fineStepDivisor: CGFloat = 5.0

/// Spacing of the rotation row's marks: a quarter turn, so the row is divided at
/// 0°, 90°, 180° and 270° — the last showing as -90° in the default -180...180
/// range. tvOS snaps to them; macOS draws them as tick marks.
let rotationTickSpacing: CGFloat = 90

/// Opens a row's range up to a value sitting outside it. Dragging the video pans
/// as far as it takes to reach the image's edges, which past a certain zoom is
/// further than the configured translation range; the row has to carry that
/// value rather than clamp it back the moment the slider is touched.
func widenedRange(_ range: ClosedRange<CGFloat>, toInclude value: CGFloat) -> ClosedRange<CGFloat> {
	guard value.isFinite else { return range }
	return min(range.lowerBound, value)...max(range.upperBound, value)
}

/// The multiples of `spacing` that fall inside `range`, used as the rotation
/// row's marks on tvOS.
func tickValues(in range: ClosedRange<CGFloat>, spacing: CGFloat) -> [CGFloat] {
	guard spacing > 0 else { return [] }
	let first = (range.lowerBound / spacing).rounded(.up)
	let last = (range.upperBound / spacing).rounded(.down)
	guard first <= last else { return [] }
	return stride(from: first, through: last, by: 1).map { $0 * spacing }
}

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
				sensitivity: isFineMode ? sensivity / fineStepDivisor : sensivity,
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
		let step = isFineMode ? sensivity / fineStepDivisor : sensivity
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

/// One labelled row of the tvOS control panel offering a short list of choices,
/// laid out like `TVSliderRow`. Left and right presses walk the list, and the
/// clickpad's select advances it.
struct TVChoiceRow<Field: Hashable, Value: Hashable>: View {
	let field: Field
	let label: String
	@Binding var value: Value
	let options: [(value: Value, label: String)]
	let focusedField: FocusState<Field?>.Binding

	private var isSelected: Bool { focusedField.wrappedValue == field }

	var body: some View {
		HStack(spacing: 14) {
			Text(label)
				.font(.subheadline)
				.foregroundStyle(isSelected ? Color.panelAccent : .primary.opacity(0.85))

			Spacer(minLength: 0)

			HStack(spacing: 10) {
				ForEach(options, id: \.value) { option in
					Text(option.label)
						.font(.subheadline)
						.fontWeight(option.value == value ? .semibold : .regular)
						.foregroundStyle(option.value == value ? Color.primary : .primary.opacity(0.45))
						.padding(.vertical, 4)
						.padding(.horizontal, 12)
						.background(
							Capsule(style: .continuous)
								.fill(option.value == value ? Color.panelAccent.opacity(0.25) : .clear)
						)
				}
			}
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
		.onMoveCommand(perform: applyMoveCommand)
		.onTapGesture { step(by: 1) }
		.contentShape(Rectangle())
		.focused(focusedField, equals: field)
		.animation(.easeInOut(duration: 0.18), value: isSelected)
	}

	private func applyMoveCommand(_ direction: MoveCommandDirection) {
		switch direction {
		case .left: step(by: -1)
		case .right: step(by: 1)
		default: break
		}
	}

	/// Wraps around, so the select button alone cycles the whole list.
	private func step(by offset: Int) {
		guard !options.isEmpty else { return }
		let current = options.firstIndex { $0.value == value } ?? 0
		let next = (current + offset + options.count) % options.count
		value = options[next].value
	}
}

#else

/// One labelled row of the iOS/macOS control panel: a native slider plus a
/// numeric field for exact values. Built as a `GridRow` so labels, sliders and
/// fields align across the rows of the enclosing `Grid`.
///
/// - Parameters:
///   - sensivity: base adjustment step of the value. On macOS the row gets a
///     stepper that nudges the value by one *fine* step — the same amount as one
///     remote press in the tvOS panel's fine mode, i.e. the sensitivity divided
///     by `fineStepDivisor`. Unused on the other platforms, where the slider and
///     the field position absolutely.
///   - tickSpacing: when non-`nil` and the range divides evenly by it, the macOS
///     slider draws tick marks that far apart. The marks are guides only — the
///     value stays continuous. Ignored on iOS and visionOS, whose sliders have
///     no tick marks.
@MainActor @ViewBuilder
func nativeSliderRow(
	label: String,
	value: Binding<CGFloat>,
	range: ClosedRange<CGFloat>,
	sensivity: CGFloat,
	tickSpacing: CGFloat? = nil
) -> some View {
	let rowRange = widenedRange(range, toInclude: value.wrappedValue)
	let clamped = Binding(
		get: { value.wrappedValue },
		set: { value.wrappedValue = min(max($0, rowRange.lowerBound), rowRange.upperBound) }
	)
	GridRow {
		// Truncate rather than wrap: the slider now holds a minimum width, so in a
		// container too narrow for the whole row the label is what gives — and
		// wrapping there degenerates into one letter per line.
		Text(label)
			.lineLimit(1)
			.help(label)
			.gridColumnAlignment(.leading)

#if os(macOS)
		// The slider is the row's flexible cell: `maxWidth: .infinity` makes it —
		// and so the enclosing `Grid` — take all the width on offer, which an
		// `NSViewRepresentable` won't do on its own since it reports a finite
		// intrinsic width. `minWidth` is the floor that keeps the ticks readable.
		TickedSlider(value: clamped, range: rowRange, tickSpacing: tickSpacing)
			.frame(minWidth: TickedSlider.minimumWidth, maxWidth: .infinity)
#else
		Slider(value: value, in: rowRange)
#endif

		TextField(
			label,
			value: Binding(
				get: { Double(clamped.wrappedValue) },
				set: { clamped.wrappedValue = CGFloat($0) }
			),
			format: .number.precision(.fractionLength(0...2))
		)
		.labelsHidden()
		.textFieldStyle(.roundedBorder)
		.multilineTextAlignment(.trailing)
		// Flexible so the field gives up a little width before the label starts
		// truncating; it still settles at 84 wherever there's room.
		.frame(minWidth: 60, idealWidth: 84, maxWidth: 84)
#if os(iOS) || os(visionOS)
		.keyboardType(.numbersAndPunctuation)
#endif

#if os(macOS)
		Stepper(label, value: clamped, in: rowRange, step: sensivity / fineStepDivisor)
			.labelsHidden()
#endif
	}
}

#if os(macOS)

/// A horizontal slider that can draw tick marks. SwiftUI's `Slider` only shows
/// them through a `step:`, which would also snap the value to that step, so this
/// wraps `NSSlider` directly: the marks are drawn as guides while the value
/// stays continuous.
struct TickedSlider: NSViewRepresentable {
	@Binding var value: CGFloat
	let range: ClosedRange<CGFloat>
	/// Distance between two marks, in value units. Marks are only drawn when the
	/// range is a whole number of these apart — `NSSlider` spaces its ticks
	/// evenly across the range, so an uneven spacing would land them off-value.
	let tickSpacing: CGFloat?

	@Environment(\.controlSize) private var controlSize

	/// Floor on the slider's width. Narrower than this the knob covers the tick
	/// marks — which is what happens when the rows are stacked in something tight
	/// like an inspector, since the label and the numeric field hold their width
	/// and the slider is the only cell that can give any up.
	static let minimumWidth: CGFloat = 90

	/// How close the knob must come to a tick mark for it to stick, in points on
	/// screen. Expressed as a distance rather than in value units so the pull
	/// feels the same whatever the row's range or width.
	private static let snapDistance: CGFloat = 6

	final class Coordinator: NSObject {
		var value: Binding<CGFloat>

		init(value: Binding<CGFloat>) {
			self.value = value
		}

		@objc func sliderChanged(_ sender: NSSlider) {
			value.wrappedValue = CGFloat(snapping(sender))
		}

		/// Pulls the dragged value onto a tick mark once it comes within
		/// `snapDistance` of one, so the quarter turns are easy to land on.
		/// Holding Option suspends it, the usual macOS "let me be precise"
		/// modifier — as do the stepper and the numeric field, which are
		/// unaffected.
		private func snapping(_ slider: NSSlider) -> Double {
			let raw = slider.doubleValue
			guard slider.numberOfTickMarks > 0,
						!NSEvent.modifierFlags.contains(.option) else { return raw }
			let span = slider.maxValue - slider.minValue
			let width = max(slider.bounds.width, 1)
			let tolerance = span * Double(TickedSlider.snapDistance) / Double(width)
			let tick = slider.closestTickMarkValue(toValue: raw)
			return abs(tick - raw) <= tolerance ? tick : raw
		}
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(value: $value)
	}

	func makeNSView(context: Context) -> NSSlider {
		let slider = NSSlider(
			target: context.coordinator,
			action: #selector(Coordinator.sliderChanged(_:))
		)
		slider.isContinuous = true
		// The row lays sliders out in a Grid column; let it stretch rather than
		// hold on to NSSlider's intrinsic width. How far it may *shrink* is
		// `sizeThatFits`' job.
		slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
		return slider
	}

	/// Take the width offered — the slider is the row's flexible cell — but never
	/// below `minimumWidth`, so the tick marks stay readable in narrow layouts.
	/// Height stays intrinsic: `NSSlider` grows it to make room for the marks.
	func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSlider, context: Context) -> CGSize? {
		let intrinsic = nsView.intrinsicContentSize
		// `nil` is the unspecified proposal and `.infinity` the "as big as you
		// like" one; both mean "state your ideal width".
		let proposed = proposal.width ?? intrinsic.width
		let width = proposed.isFinite ? proposed : intrinsic.width
		return CGSize(width: max(width, Self.minimumWidth), height: intrinsic.height)
	}

	func updateNSView(_ slider: NSSlider, context: Context) {
		context.coordinator.value = $value
		slider.minValue = Double(range.lowerBound)
		slider.maxValue = Double(range.upperBound)
		slider.numberOfTickMarks = tickMarkCount
		slider.tickMarkPosition = .below
		// Guides only — the knob still stops anywhere between two marks.
		slider.allowsTickMarkValuesOnly = false
		slider.controlSize = NSControl.ControlSize(controlSize)
		if slider.doubleValue != Double(value) {
			slider.doubleValue = Double(value)
		}
	}

	/// Number of evenly spaced marks (both ends included) for `tickSpacing`, or 0
	/// when the range doesn't divide evenly into it.
	private var tickMarkCount: Int {
		guard let tickSpacing, tickSpacing > 0 else { return 0 }
		let span = range.upperBound - range.lowerBound
		let steps = (span / tickSpacing).rounded()
		guard steps >= 1, abs(steps * tickSpacing - span) < 0.0001 else { return 0 }
		return Int(steps) + 1
	}
}

private extension NSControl.ControlSize {
	/// SwiftUI's `controlSize` environment doesn't reach an `NSViewRepresentable`
	/// on its own; the panel sets `.large`, so carry it across by hand.
	init(_ controlSize: ControlSize) {
		switch controlSize {
		case .mini: self = .mini
		case .small: self = .small
		case .regular: self = .regular
		case .large, .extraLarge: self = .large
		@unknown default: self = .regular
		}
	}
}

#endif

#endif

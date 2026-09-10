//
//  RTSPMaskControls.swift
//  SwiftRTSPPlayer
//

import SwiftUI

/// The mask tab of `RTSPTransformControlPanel`, usable on its own: a choice of
/// anchor and slider rows for the four sides of a `VideoMask`, each the
/// fraction hidden from that edge. On iOS and macOS the rows are native sliders
/// with a numeric field for exact values; on tvOS they are the focus-driven
/// swipe sliders of the control panel.
///
/// Embed it directly to build a custom panel:
///
/// ```swift
/// RTSPMaskControls(mask: $mask)
/// ```
public struct RTSPMaskControls: View {

	@Binding private var mask: VideoMask

	private let maskRange: ClosedRange<CGFloat>
	private let maskSensivity: CGFloat
	private let isFineMode: Bool

#if os(tvOS)
	private enum Field: Hashable {
		case anchor, left, right, top, bottom
	}
	@FocusState private var focusedField: Field?
#endif

	/// - Parameters:
	///   - maskRange: how far each side may reach. The default stops short of
	///     half the picture, so the two sides of an axis can never close it.
	///   - maskSensivity: base adjustment step of the value, which on macOS the
	///     row's stepper divides by `fineStepDivisor`. On tvOS a remote press
	///     already takes that division (see `remoteSensivity`). Unused on iOS and
	///     visionOS, where the sliders and fields are absolute.
	///   - isFineMode: tvOS only — shrinks the adjustment step for precise moves.
	public init(
		mask: Binding<VideoMask>,
		maskRange: ClosedRange<CGFloat> = 0...0.45,
		maskSensivity: CGFloat = 0.05,
		isFineMode: Bool = false
	) {
		self._mask = mask
		self.maskRange = maskRange
		self.maskSensivity = maskSensivity
		self.isFineMode = isFineMode
	}

	private var rows: [(key: String, value: Binding<CGFloat>)] {
		[
			("mask.left", Binding(get: { mask.left }, set: { mask.left = $0 })),
			("mask.right", Binding(get: { mask.right }, set: { mask.right = $0 })),
			("mask.top", Binding(get: { mask.top }, set: { mask.top = $0 })),
			("mask.bottom", Binding(get: { mask.bottom }, set: { mask.bottom = $0 }))
		]
	}

	private func label(_ key: String) -> String {
		String(localized: String.LocalizationValue(key), bundle: .module)
	}

	private var anchor: Binding<VideoMask.Anchor> {
		Binding(get: { mask.anchor }, set: { mask.anchor = $0 })
	}

	private var anchorOptions: [(value: VideoMask.Anchor, label: String)] {
		[
			(.image, label("mask.anchor.image")),
			(.view, label("mask.anchor.view"))
		]
	}

#if os(tvOS)
	/// A mask side spans a fraction of the picture where the other tabs' rows
	/// span degrees or points, so a remote press starts a notch below the base
	/// step — and fine mode still takes another off that.
	private var remoteSensivity: CGFloat { maskSensivity / fineStepDivisor }
#endif

	public var body: some View {
#if os(tvOS)
		VStack(alignment: .leading, spacing: 8) {
			TVChoiceRow(
				field: Field.anchor,
				label: label("mask.anchor"),
				value: anchor,
				options: anchorOptions,
				focusedField: $focusedField
			)
			TVSliderRow(
				field: Field.left,
				label: label("mask.left"),
				value: rows[0].value,
				range: maskRange,
				sensivity: remoteSensivity,
				isFineMode: isFineMode,
				focusedField: $focusedField
			)
			TVSliderRow(
				field: Field.right,
				label: label("mask.right"),
				value: rows[1].value,
				range: maskRange,
				sensivity: remoteSensivity,
				isFineMode: isFineMode,
				focusedField: $focusedField
			)
			TVSliderRow(
				field: Field.top,
				label: label("mask.top"),
				value: rows[2].value,
				range: maskRange,
				sensivity: remoteSensivity,
				isFineMode: isFineMode,
				focusedField: $focusedField
			)
			TVSliderRow(
				field: Field.bottom,
				label: label("mask.bottom"),
				value: rows[3].value,
				range: maskRange,
				sensivity: remoteSensivity,
				isFineMode: isFineMode,
				focusedField: $focusedField
			)
		}
#else
		VStack(alignment: .leading, spacing: 18) {
			HStack(spacing: 16) {
				Text(label("mask.anchor"))
				Picker(selection: anchor) {
					ForEach(anchorOptions, id: \.value) { option in
						Text(option.label).tag(option.value)
					}
				} label: {
					EmptyView()
				}
				.pickerStyle(.segmented)
				.labelsHidden()
			}
			Grid(horizontalSpacing: 16, verticalSpacing: 18) {
				ForEach(rows, id: \.key) { row in
					nativeSliderRow(
						label: label(row.key),
						value: row.value,
						range: maskRange,
						sensivity: maskSensivity
					)
				}
			}
		}
		.padding()
#endif
	}
}

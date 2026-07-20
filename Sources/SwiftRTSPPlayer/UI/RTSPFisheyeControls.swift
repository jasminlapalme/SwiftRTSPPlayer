//
//  RTSPFisheyeControls.swift
//  SwiftRTSPPlayer
//

import SwiftUI

/// The fisheye tab of `RTSPTransformControlPanel`, usable on its own: slider
/// rows for the four distortion coefficients of `FisheyeCorrection`. On iOS and
/// macOS the rows are native sliders with a numeric field for exact values; on
/// tvOS they are the focus-driven swipe sliders of the control panel.
///
/// Embed it directly to build a custom panel:
///
/// ```swift
/// RTSPFisheyeControls(fisheyeCorrection: $fisheye)
/// ```
public struct RTSPFisheyeControls: View {

	@Binding private var fisheyeCorrection: FisheyeCorrection

	private let fisheyeRange: ClosedRange<CGFloat>
	private let fisheyeSensivity: CGFloat
	private let isFineMode: Bool

#if os(tvOS)
	private enum Field: Hashable {
		case k1v, k2v, k3v, k4v
	}
	@FocusState private var focusedField: Field?
#endif

	/// - Parameters:
	///   - fisheyeSensivity: step size of one tvOS remote press (divided by 5 in
	///     fine mode). Unused on the other platforms, where the sliders are absolute.
	///   - isFineMode: tvOS only — shrinks the adjustment step for precise moves.
	public init(
		fisheyeCorrection: Binding<FisheyeCorrection>,
		fisheyeRange: ClosedRange<CGFloat> = -1...1,
		fisheyeSensivity: CGFloat = 0.05,
		isFineMode: Bool = false
	) {
		self._fisheyeCorrection = fisheyeCorrection
		self.fisheyeRange = fisheyeRange
		self.fisheyeSensivity = fisheyeSensivity
		self.isFineMode = isFineMode
	}

	private var rows: [(key: String, value: Binding<CGFloat>)] {
		[
			("fisheye.k1", Binding(get: { fisheyeCorrection.k1v }, set: { fisheyeCorrection.k1v = $0 })),
			("fisheye.k2", Binding(get: { fisheyeCorrection.k2v }, set: { fisheyeCorrection.k2v = $0 })),
			("fisheye.k3", Binding(get: { fisheyeCorrection.k3v }, set: { fisheyeCorrection.k3v = $0 })),
			("fisheye.k4", Binding(get: { fisheyeCorrection.k4v }, set: { fisheyeCorrection.k4v = $0 }))
		]
	}

	private func label(_ key: String) -> String {
		String(localized: String.LocalizationValue(key), bundle: .module)
	}

	public var body: some View {
#if os(tvOS)
		VStack(alignment: .leading, spacing: 8) {
			TVSliderRow(
				field: Field.k1v,
				label: label("fisheye.k1"),
				value: rows[0].value,
				range: fisheyeRange,
				sensivity: fisheyeSensivity,
				isFineMode: isFineMode,
				focusedField: $focusedField
			)
			TVSliderRow(
				field: Field.k2v,
				label: label("fisheye.k2"),
				value: rows[1].value,
				range: fisheyeRange,
				sensivity: fisheyeSensivity,
				isFineMode: isFineMode,
				focusedField: $focusedField
			)
			TVSliderRow(
				field: Field.k3v,
				label: label("fisheye.k3"),
				value: rows[2].value,
				range: fisheyeRange,
				sensivity: fisheyeSensivity,
				isFineMode: isFineMode,
				focusedField: $focusedField
			)
			TVSliderRow(
				field: Field.k4v,
				label: label("fisheye.k4"),
				value: rows[3].value,
				range: fisheyeRange,
				sensivity: fisheyeSensivity,
				isFineMode: isFineMode,
				focusedField: $focusedField
			)
		}
#else
		Grid(horizontalSpacing: 16, verticalSpacing: 18) {
			ForEach(rows, id: \.key) { row in
				nativeSliderRow(label: label(row.key), value: row.value, range: fisheyeRange)
			}
		}
		.padding()
#endif
	}
}

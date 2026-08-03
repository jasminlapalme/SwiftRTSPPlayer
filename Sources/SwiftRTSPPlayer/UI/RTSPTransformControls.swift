//
//  RTSPTransformControls.swift
//  SwiftRTSPPlayer
//

import SwiftUI

/// The transform tab of `RTSPTransformControlPanel`, usable on its own: slider
/// rows for the player's scale, translation and rotation. On iOS and macOS the
/// rows are native sliders with a numeric field for exact values; on tvOS they
/// are the focus-driven swipe sliders of the control panel.
///
/// Embed it directly to build a custom panel:
///
/// ```swift
/// RTSPTransformControls(
///     scale: $scale,
///     translation: $translation,
///     rotation: $rotation
/// )
/// ```
public struct RTSPTransformControls: View {

	@Binding private var scale: CGFloat
	@Binding private var translation: CGPoint
	@Binding private var rotation: CGFloat

	private let scaleRange: ClosedRange<CGFloat>
	private let translationXRange: ClosedRange<CGFloat>
	private let translationYRange: ClosedRange<CGFloat>
	private let rotationRange: ClosedRange<CGFloat>

	private let scaleSensivity: CGFloat
	private let translationXSensivity: CGFloat
	private let translationYSensivity: CGFloat
	private let rotationSensivity: CGFloat
	private let isFineMode: Bool

#if os(tvOS)
	private enum Field: Hashable {
		case scale, transX, transY, rotation
	}
	@FocusState private var focusedField: Field?
#endif

	/// - Parameters:
	///   - sensivities: step size of one tvOS remote press (divided by
	///     `fineStepDivisor` in fine mode) and, on macOS, of one click of the
	///     row's stepper — which always takes a fine step. Unused on iOS and
	///     visionOS, where the sliders and fields are absolute.
	///   - isFineMode: tvOS only — shrinks the adjustment step for precise moves.
	public init(
		scale: Binding<CGFloat>,
		translation: Binding<CGPoint>,
		rotation: Binding<CGFloat>,
		scaleRange: ClosedRange<CGFloat> = 0.1...3.0,
		translationXRange: ClosedRange<CGFloat> = -500...500,
		translationYRange: ClosedRange<CGFloat> = -500...500,
		rotationRange: ClosedRange<CGFloat> = -180...180,
		scaleSensivity: CGFloat = 0.1,
		translationXSensivity: CGFloat = 10.0,
		translationYSensivity: CGFloat = 10.0,
		rotationSensivity: CGFloat = 1.0,
		isFineMode: Bool = false
	) {
		self._scale = scale
		self._translation = translation
		self._rotation = rotation
		self.scaleRange = scaleRange
		self.translationXRange = translationXRange
		self.translationYRange = translationYRange
		self.rotationRange = rotationRange
		self.scaleSensivity = scaleSensivity
		self.translationXSensivity = translationXSensivity
		self.translationYSensivity = translationYSensivity
		self.rotationSensivity = rotationSensivity
		self.isFineMode = isFineMode
	}

	private var translationX: Binding<CGFloat> {
		Binding(get: { translation.x }, set: { translation.x = $0 })
	}

	private var translationY: Binding<CGFloat> {
		Binding(get: { translation.y }, set: { translation.y = $0 })
	}

	public var body: some View {
#if os(tvOS)
		VStack(alignment: .leading, spacing: 8) {
			TVSliderRow(
				field: Field.scale,
				label: String(localized: "transform.scale", bundle: .module),
				value: $scale,
				range: scaleRange,
				sensivity: scaleSensivity,
				isFineMode: isFineMode,
				focusedField: $focusedField
			)
			TVSliderRow(
				field: Field.transX,
				label: String(localized: "transform.translateX", bundle: .module),
				value: translationX,
				range: translationXRange,
				sensivity: translationXSensivity,
				isFineMode: isFineMode,
				focusedField: $focusedField
			)
			TVSliderRow(
				field: Field.transY,
				label: String(localized: "transform.translateY", bundle: .module),
				value: translationY,
				range: translationYRange,
				sensivity: translationYSensivity,
				isFineMode: isFineMode,
				focusedField: $focusedField
			)
			TVSliderRow(
				field: Field.rotation,
				label: String(localized: "transform.rotation", bundle: .module),
				value: $rotation,
				range: rotationRange,
				sensivity: rotationSensivity,
				ticks: tickValues(in: rotationRange, spacing: rotationTickSpacing),
				isFineMode: isFineMode,
				focusedField: $focusedField
			)
		}
#else
		Grid(horizontalSpacing: 16, verticalSpacing: 18) {
			nativeSliderRow(
				label: String(localized: "transform.scale", bundle: .module),
				value: $scale,
				range: scaleRange,
				sensivity: scaleSensivity
			)
			nativeSliderRow(
				label: String(localized: "transform.translateX", bundle: .module),
				value: translationX,
				range: translationXRange,
				sensivity: translationXSensivity
			)
			nativeSliderRow(
				label: String(localized: "transform.translateY", bundle: .module),
				value: translationY,
				range: translationYRange,
				sensivity: translationYSensivity
			)
			nativeSliderRow(
				label: String(localized: "transform.rotation", bundle: .module),
				value: $rotation,
				range: rotationRange,
				sensivity: rotationSensivity,
				tickSpacing: rotationTickSpacing
			)
		}
		.padding()
#endif
	}
}

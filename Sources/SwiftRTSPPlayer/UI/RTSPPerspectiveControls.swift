//
//  RTSPPerspectiveControls.swift
//  SwiftRTSPPlayer
//

import SwiftUI

/// The perspective tab of `RTSPTransformControlPanel`: pick a frame corner, then move where it falls in the picture.
public struct RTSPPerspectiveControls: View {

	@Binding private var perspective: VideoPerspective

	private let perspectiveRange: ClosedRange<CGFloat>
	private let perspectiveSensivity: CGFloat
	private let isFineMode: Bool

	@State private var corner: VideoPerspective.Corner = .topLeft

#if os(tvOS)
	private enum Field: Hashable {
		case corner, horizontal, vertical
	}
	@FocusState private var focusedField: Field?
#endif

	/// `perspectiveSensivity` is the base step, as for the other tabs; `isFineMode` shrinks it on tvOS.
	public init(
		perspective: Binding<VideoPerspective>,
		perspectiveRange: ClosedRange<CGFloat> = VideoPerspective.editableRange,
		perspectiveSensivity: CGFloat = 0.01,
		isFineMode: Bool = false
	) {
		self._perspective = perspective
		self.perspectiveRange = perspectiveRange
		self.perspectiveSensivity = perspectiveSensivity
		self.isFineMode = isFineMode
	}

	private func label(_ key: String) -> String {
		String(localized: String.LocalizationValue(key), bundle: .module)
	}

	private var horizontal: Binding<CGFloat> {
		Binding(get: { perspective[corner].x }, set: { perspective[corner].x = $0 })
	}

	private var vertical: Binding<CGFloat> {
		Binding(get: { perspective[corner].y }, set: { perspective[corner].y = $0 })
	}

	private var cornerOptions: [(value: VideoPerspective.Corner, label: String)] {
		[
			(.topLeft, label("perspective.corner.topLeft")),
			(.topRight, label("perspective.corner.topRight")),
			(.bottomRight, label("perspective.corner.bottomRight")),
			(.bottomLeft, label("perspective.corner.bottomLeft"))
		]
	}

	public var body: some View {
#if os(tvOS)
		VStack(alignment: .leading, spacing: 8) {
			TVChoiceRow(
				field: Field.corner,
				label: label("perspective.corner"),
				value: $corner,
				options: [(.topLeft, "↖"), (.topRight, "↗"), (.bottomRight, "↘"), (.bottomLeft, "↙")],
				focusedField: $focusedField
			)
			TVSliderRow(
				field: Field.horizontal,
				label: label("perspective.horizontal"),
				value: horizontal,
				range: perspectiveRange,
				sensivity: perspectiveSensivity,
				isFineMode: isFineMode,
				focusedField: $focusedField
			)
			TVSliderRow(
				field: Field.vertical,
				label: label("perspective.vertical"),
				value: vertical,
				range: perspectiveRange,
				sensivity: perspectiveSensivity,
				isFineMode: isFineMode,
				focusedField: $focusedField
			)
		}
#else
		VStack(alignment: .leading, spacing: 18) {
			HStack(spacing: 16) {
				Text(label("perspective.corner"))
				Picker(selection: $corner) {
					ForEach(cornerOptions, id: \.value) { option in
						Image(systemName: option.value.arrowSymbol)
							.accessibilityLabel(option.label)
							.tag(option.value)
					}
				} label: {
					EmptyView()
				}
				.pickerStyle(.segmented)
				.labelsHidden()
			}
			Grid(horizontalSpacing: 16, verticalSpacing: 18) {
				nativeSliderRow(
					label: label("perspective.horizontal"),
					value: horizontal,
					range: perspectiveRange,
					sensivity: perspectiveSensivity
				)
				nativeSliderRow(
					label: label("perspective.vertical"),
					value: vertical,
					range: perspectiveRange,
					sensivity: perspectiveSensivity
				)
			}
		}
		.padding()
#endif
	}
}

private extension VideoPerspective.Corner {
	/// Arrows rather than words: four of them fit on one row in every language.
	var arrowSymbol: String {
		switch self {
		case .topLeft: "arrow.up.left"
		case .topRight: "arrow.up.right"
		case .bottomRight: "arrow.down.right"
		case .bottomLeft: "arrow.down.left"
		}
	}
}

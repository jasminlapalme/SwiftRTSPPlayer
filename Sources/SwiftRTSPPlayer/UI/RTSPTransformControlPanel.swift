//
//  RTSPTransformControlPanel.swift
//  SwiftRTSPPlayer
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Overlay panel that exposes the player's transform (scale, translation, rotation)
/// through a styled, swipe-driven UI. The library ships the control; the client
/// decides if/where to show it — typically as an `.overlay` on `RTSPPlayerView`.
///
/// ```swift
/// RTSPPlayerView(url: url, rotation: rotation, scale: scale, translation: translation)
///     .overlay(alignment: .bottom) {
///         RTSPTransformControlPanel(
///             scale: $scale,
///             translation: $translation,
///             rotation: $rotation
///         )
///         .padding()
///     }
/// ```
public struct RTSPTransformControlPanel: View {

	@Binding private var scale: CGFloat
	@Binding private var translation: CGPoint
	@Binding private var rotation: CGFloat
	@Binding private var fisheyeCorrection: FisheyeCorrection

	private let hasFisheye: Bool
	private let scaleRange: ClosedRange<CGFloat>
	private let translationXRange: ClosedRange<CGFloat>
	private let translationYRange: ClosedRange<CGFloat>
	private let rotationRange: ClosedRange<CGFloat>
	private let fisheyeRange: ClosedRange<CGFloat>

	private let defaultScale: CGFloat
	private let defaultTranslation: CGPoint
	private let defaultRotation: CGFloat
	private let defaultFisheye: FisheyeCorrection

	private let scaleSensivity: CGFloat
	private let translationXSensivity: CGFloat
	private let translationYSensivity: CGFloat
	private let rotationSensivity: CGFloat
	private let fisheyeSensivity: CGFloat

	private let closeAction: () -> Void
	private let configureAction: () -> Void

#if !os(tvOS)
	@State private var selectedField: Field?
#endif
	@State private var isFineMode: Bool = false
	@State private var selectedTab: Tab = .transform
	@FocusState private var focusedField: Field?
	@FocusState private var focusedTab: Tab?

	private enum Field: Hashable {
		case scale, transX, transY, rotation
		case k1v, k2v, k3v, k4v
	}

	private enum Tab: Hashable {
		case transform, fisheye
	}

	public init(
		scale: Binding<CGFloat>,
		translation: Binding<CGPoint>,
		rotation: Binding<CGFloat>,
		fisheyeCorrection: Binding<FisheyeCorrection>? = nil,
		scaleRange: ClosedRange<CGFloat> = 0.1...3.0,
		translationXRange: ClosedRange<CGFloat> = -500...500,
		translationYRange: ClosedRange<CGFloat> = -500...500,
		rotationRange: ClosedRange<CGFloat> = -180...180,
		fisheyeRange: ClosedRange<CGFloat> = -1...1,
		defaultScale: CGFloat = 1.0,
		defaultTranslation: CGPoint = .zero,
		defaultRotation: CGFloat = 0,
		defaultFisheye: FisheyeCorrection = .identity,
		scaleSensivity: CGFloat = 0.1,
		translationXSensivity: CGFloat = 10.0,
		translationYSensivity: CGFloat = 10.0,
		rotationSensivity: CGFloat = 1.0,
		fisheyeSensivity: CGFloat = 0.05,
		closeAction: @escaping () -> Void = {},
		configureAction: @escaping () -> Void = {}
	) {
		self._scale = scale
		self._translation = translation
		self._rotation = rotation
		self._fisheyeCorrection = fisheyeCorrection ?? .constant(.identity)
		self.hasFisheye = fisheyeCorrection != nil
		self.scaleRange = scaleRange
		self.translationXRange = translationXRange
		self.translationYRange = translationYRange
		self.rotationRange = rotationRange
		self.fisheyeRange = fisheyeRange
		self.defaultScale = defaultScale
		self.defaultTranslation = defaultTranslation
		self.defaultRotation = defaultRotation
		self.defaultFisheye = defaultFisheye
		self.scaleSensivity = scaleSensivity
		self.translationXSensivity = translationXSensivity
		self.translationYSensivity = translationYSensivity
		self.rotationSensivity = rotationSensivity
		self.fisheyeSensivity = fisheyeSensivity
		self.closeAction = closeAction
		self.configureAction = configureAction
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			headerBar
			if selectedTab == .transform || !hasFisheye {
				transformRows
			} else {
				fisheyeRows
			}
			footer
		}
		.padding(16)
		.background(panelBackground)
		.frame(maxWidth: 720)
#if os(tvOS)
		// Focus → tab switch. When entering from outside, snap back to
		// the active tab to avoid an accidental geometric switch.
		.onChange(of: focusedTab) { oldValue, newValue in
			guard let newValue else { return }
			if oldValue == nil && newValue != selectedTab {
				focusedTab = selectedTab
			} else { selectedTab = newValue }
		}
		.onAppear {
			self.focusedTab = .transform
		}
#else
		.onChange(of: focusedField) { _, newValue in
			if let newValue { selectedField = newValue }
		}
#endif
	}

	// MARK: - Reset

	private func resetAll() {
		if hasFisheye && selectedTab == .fisheye {
			fisheyeCorrection = defaultFisheye
		} else {
			scale = defaultScale
			translation = defaultTranslation
			rotation = defaultRotation
		}
	}
}

// MARK: - Subviews

private extension RTSPTransformControlPanel {

	@ViewBuilder
	var transformRows: some View {
		row(
			field: .scale,
			label: String(localized: "transform.scale", bundle: .module),
			value: $scale,
			range: scaleRange,
			sensivity: scaleSensivity
		)
		row(
			field: .transX,
			label: String(localized: "transform.translateX", bundle: .module),
			value: Binding(get: { translation.x }, set: { translation.x = $0 }),
			range: translationXRange,
			sensivity: translationXSensivity
		)
		row(
			field: .transY,
			label: String(localized: "transform.translateY", bundle: .module),
			value: Binding(get: { translation.y }, set: { translation.y = $0 }),
			range: translationYRange,
			sensivity: translationYSensivity
		)
		row(
			field: .rotation,
			label: String(localized: "transform.rotation", bundle: .module),
			value: $rotation,
			range: rotationRange,
			sensivity: rotationSensivity,
			ticks: [-180, -90, 0, 90, 180]
		)
	}

	@ViewBuilder
	private var fisheyeRows: some View {
		row(
			field: .k1v,
			label: String(localized: "fisheye.k1", bundle: .module),
			value: Binding(get: { fisheyeCorrection.k1v }, set: { fisheyeCorrection.k1v = $0 }),
			range: fisheyeRange,
			sensivity: fisheyeSensivity
		)
		row(
			field: .k2v,
			label: String(localized: "fisheye.k2", bundle: .module),
			value: Binding(get: { fisheyeCorrection.k2v }, set: { fisheyeCorrection.k2v = $0 }),
			range: fisheyeRange,
			sensivity: fisheyeSensivity
		)
		row(
			field: .k3v,
			label: String(localized: "fisheye.k3", bundle: .module),
			value: Binding(get: { fisheyeCorrection.k3v }, set: { fisheyeCorrection.k3v = $0 }),
			range: fisheyeRange,
			sensivity: fisheyeSensivity
		)
		row(
			field: .k4v,
			label: String(localized: "fisheye.k4", bundle: .module),
			value: Binding(get: { fisheyeCorrection.k4v }, set: { fisheyeCorrection.k4v = $0 }),
			range: fisheyeRange,
			sensivity: fisheyeSensivity
		)
	}

	// MARK: - Header bar (tabs + close)

	private var headerBar: some View {
		HStack(spacing: 10) {
			tabPill
			Spacer(minLength: 0)
			Button(
				String(localized: "transform.configure", bundle: .module),
				systemImage: "gear",
				action: configureAction
			)
			.labelStyle(.iconOnly)
			.controlSize(.small)
			Button(
				String(localized: "transform.close", bundle: .module),
				systemImage: "xmark",
				action: closeAction
			)
			.labelStyle(.iconOnly)
			.controlSize(.small)
		}
		.padding()
	}

	private var tabPill: some View {
		HStack(spacing: 16) {
			tabButton(
				.transform,
				label: String(localized: "transform.tab.transform", bundle: .module)
			)
			if hasFisheye {
				tabButton(
					.fisheye,
					label: String(localized: "transform.tab.fisheye", bundle: .module)
				)
			}
		}
		.padding(.vertical, 6)
		.padding(.horizontal, 12)
		.background(
			Capsule(style: .continuous)
				.fill(Color.primary.opacity(0.10))
		)
	}

	@ViewBuilder
	private func tabButton(_ tab: Tab, label: String) -> some View {
		let isActive = (selectedTab == tab)
		let isFocus = (focusedTab == tab)
		let content = Text(label)
			.font(.headline)
			.fontWeight(isFocus || isActive ? .semibold : .regular)
			.foregroundStyle(
				isFocus
					? Color.black
					: (isActive ? Color.primary : Color.primary.opacity(0.6))
			)
			.padding(.vertical, 10)
			.padding(.horizontal, 24)
			.background(
				Capsule(style: .continuous)
					.fill(isFocus ? Color.white : Color.clear)
					.shadow(
						color: Color.black.opacity(isFocus ? 0.30 : 0),
						radius: isFocus ? 12 : 0,
						y: isFocus ? 8 : 0
					)
			)
			.scaleEffect(isFocus ? 1.1 : 1.0)
			.animation(.easeInOut(duration: 0.18), value: isFocus)
			.animation(.easeInOut(duration: 0.18), value: isActive)
			.contentShape(Capsule())
#if os(tvOS)
		content
			.focusable(true)
			.focused($focusedTab, equals: tab)
#else
		Button { selectedTab = tab } label: { content }
			.buttonStyle(.plain)
#endif
	}

	// MARK: - Footer

	private var footer: some View {
		HStack {
			Button {
				resetAll()
			} label: {
				Label(
					String(localized: "transform.allDefaults", bundle: .module),
					systemImage: "arrow.counterclockwise"
				)
			}

			Spacer()

			Button(String(localized: "transform.fine", bundle: .module)) {
				isFineMode.toggle()
			}
			.foregroundStyle(isFineMode ? Color.panelAccent : .primary)
			.font(isFineMode ? .body.bold() : .body)
		}
		.padding()
	}

	// MARK: - Row

	@ViewBuilder
	private func row(
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

	private func isFieldSelected(_ field: Field) -> Bool {
#if os(tvOS)
		return focusedField == field
#else
		return selectedField == field
#endif
	}

#if os(tvOS)
	private func applyMoveCommand(
		_ direction: MoveCommandDirection,
		value: Binding<CGFloat>,
		range: ClosedRange<CGFloat>,
		sensivity: CGFloat,
		ticks: [CGFloat]
	) {
		let useTicks = !isFineMode && !ticks.isEmpty
		let span = range.upperBound - range.lowerBound
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

	// MARK: - Panel background

	private var panelBackground: some View {
		// Custom semi-transparent surface — no system blur, so the video shows
		// crisply behind the panel. Adaptive low-opacity veil keeps text legible.
		RoundedRectangle(cornerRadius: 18, style: .continuous)
			.fill(Color.panelSurface)
			.overlay(
				RoundedRectangle(cornerRadius: 18, style: .continuous)
					.strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
			)
			.shadow(color: .black.opacity(0.22), radius: 14, y: 6)
	}
}

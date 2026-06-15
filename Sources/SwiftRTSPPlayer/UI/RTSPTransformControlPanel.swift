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
	private let cameraURL: Binding<URL?>?

#if !os(tvOS)
	@State var selectedField: Field?
#endif
	@State var isFineMode: Bool = false
	@State private var selectedTab: Tab = .transform
	/// Held here (not in `ONVIFCameraListView`) so the typed ONVIF credentials
	/// persist when the user switches tabs and comes back to Cameras.
	@State private var onvifUsername = ""
	@State private var onvifPassword = ""
	/// Height of the fixed-layout tabs (slider rows + footer), used to give the
	/// cameras tab the same height so the panel doesn't resize between tabs.
	@State private var fixedTabHeight: CGFloat?
	@FocusState var focusedField: Field?
	@FocusState private var focusedTab: Tab?

	enum Field: Hashable {
		case scale, transX, transY, rotation
		case k1v, k2v, k3v, k4v
	}

	private enum Tab: Hashable {
		case transform, fisheye, cameras
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
		configureAction: @escaping () -> Void = {},
		cameraURL: Binding<URL?>? = nil
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
		self.cameraURL = cameraURL
	}

	private var hasCameras: Bool { cameraURL != nil }

	/// The tab whose content is shown — falls back to transform when the
	/// selected tab's feature isn't enabled.
	private var effectiveTab: Tab {
		switch selectedTab {
		case .fisheye:
			return hasFisheye ? .fisheye : .transform
		case .cameras:
			return hasCameras ? .cameras : .transform
		case .transform:
			return .transform
		}
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			headerBar
			switch effectiveTab {
			case .transform:
				fixedTab { transformRows }
			case .fisheye:
				fixedTab { fisheyeRows }
			case .cameras:
				if let cameraURL {
					// Match the fixed tabs' height so switching doesn't resize
					// the panel; falls back to the view's natural size until a
					// fixed tab has been measured.
					ONVIFCameraListView(
						currentURL: cameraURL,
						username: $onvifUsername,
						password: $onvifPassword
					)
					.frame(height: fixedTabHeight, alignment: .top)
				}
			}
		}
		.padding(16)
		.background(panelBackground)
		.frame(maxWidth: 720)
		.onPreferenceChange(FixedTabHeightKey.self) { height in
			if height > 0 { fixedTabHeight = height }
		}
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

	/// The slider-row tabs share their layout with the footer; wrapping them
	/// together lets us measure that combined height and mirror it onto the
	/// cameras tab (which has no footer).
	@ViewBuilder
	private func fixedTab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			content()
			footer
		}
		.background(
			GeometryReader { proxy in
				Color.clear.preference(key: FixedTabHeightKey.self, value: proxy.size.height)
			}
		)
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

/// Reports the measured height of the fixed-layout tabs.
private struct FixedTabHeightKey: PreferenceKey {
	static let defaultValue: CGFloat = 0
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		value = max(value, nextValue())
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
				systemImage: "crop.rotate",
				label: String(localized: "transform.tab.transform", bundle: .module)
			)
			if hasFisheye {
				tabButton(
					.fisheye,
					systemImage: "camera.aperture",
					label: String(localized: "transform.tab.fisheye", bundle: .module)
				)
			}
			if hasCameras {
				tabButton(
					.cameras,
					systemImage: "video",
					label: String(localized: "transform.tab.cameras", bundle: .module)
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
	private func tabButton(_ tab: Tab, systemImage: String, label: String) -> some View {
		let isActive = (selectedTab == tab)
		let isFocus = (focusedTab == tab)
		let content = Image(systemName: systemImage)
			.font(.body)
			.fontWeight(isFocus || isActive ? .semibold : .regular)
			.foregroundStyle(
				isFocus
					? Color.black
					: (isActive ? Color.primary : Color.primary.opacity(0.6))
			)
			.frame(width: 24, height: 20)
			.padding(.vertical, 10)
			.padding(.horizontal, 18)
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
			.accessibilityLabel(label)
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

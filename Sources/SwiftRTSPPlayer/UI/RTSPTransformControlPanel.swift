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

/// Overlay panel that exposes the player's transform (scale, translation,
/// rotation) — and optionally fisheye correction and camera selection — through
/// tabs. On iOS and macOS the tabs use native controls (sliders, numeric
/// fields, segmented tabs); on tvOS they use a focus-driven, swipe-based UI.
/// The library ships the control; the client decides if/where to show it —
/// typically as an `.overlay` on `RTSPPlayerView`.
///
/// The tabs' contents are also public views — `RTSPTransformControls`,
/// `RTSPFisheyeControls` and `RTSPCameraListView` — for clients that want to
/// compose their own panel instead.
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
	private let cameraURL: Binding<RTSPCameraSelection?>?
	private let managedCredentials: [RTSPManagedCredentials]

	/// Fine mode is a tvOS affordance: it shrinks the remote's adjustment step.
	/// The native sliders elsewhere position absolutely, so the state stays
	/// `false` there and the toggle is not shown.
	@State private var isFineMode: Bool = false
	@State private var selectedTab: Tab = .transform
	/// Held here (not in `ONVIFCameraListView`) so the typed ONVIF credentials
	/// persist when the user switches tabs and comes back to Cameras.
	@State private var onvifUsername = ""
	@State private var onvifPassword = ""
	/// Held here for the same reason as the credentials: the typed manual RTSP
	/// URL persists when the user switches tabs and comes back to Cameras.
	@State private var onvifManualURL = ""
	/// Which credential source the Cameras tab uses: the `name` of a managed
	/// credential set, or `nil` to use the manually typed username/password.
	/// Held here so the choice survives tab switches.
	@State private var selectedCredentialID: String?
	/// Height of the fixed-layout tabs (slider rows + footer), used to give the
	/// cameras tab the same height so the panel doesn't resize between tabs.
	@State private var fixedTabHeight: CGFloat?
#if os(tvOS)
	@FocusState private var focusedTab: Tab?
#endif

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
		cameraURL: Binding<RTSPCameraSelection?>? = nil,
		managedCredentials: [RTSPManagedCredentials] = []
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
		self.cameraURL = cameraURL
		self.managedCredentials = managedCredentials
		// Seed the cameras-tab fields from the stream already in play, so
		// reopening the panel shows the current URL and restores its source. The
		// URL is credential-free; the tagged credentials say how it authenticates.
		let seed = CameraFieldSeed(selection: cameraURL?.wrappedValue, managedCredentials: managedCredentials)
		self._onvifUsername = State(initialValue: seed.username)
		self._onvifPassword = State(initialValue: seed.password)
		self._onvifManualURL = State(initialValue: seed.manualURL)
		self._selectedCredentialID = State(initialValue: seed.credentialID)
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
				fixedTab { transformControls }
			case .fisheye:
				fixedTab { fisheyeControls }
			case .cameras:
				if let cameraURL {
					// Match the fixed tabs' height so switching doesn't resize
					// the panel; falls back to the view's natural size until a
					// fixed tab has been measured.
					ScrollView {
						ONVIFCameraListView(
							currentSelection: cameraURL,
							username: $onvifUsername,
							password: $onvifPassword,
							manualURL: $onvifManualURL,
							managedCredentials: managedCredentials,
							selectedCredentialID: $selectedCredentialID
						).padding(.leading).padding(.trailing)
					}
					.frame(height: fixedTabHeight, alignment: .top)
				}
			}
		}
		.padding(16)
#if os(macOS)
		.controlSize(.large)
#endif
		.background(panelBackground)
#if os(tvOS)
		.frame(maxWidth: 720)
#else
		.frame(maxWidth: 420)
#endif
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
		// The remote's Menu/back button dismisses the panel, standing in for the
		// close button that other platforms show in the header.
		.onExitCommand(perform: closeAction)
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

	var transformControls: some View {
		RTSPTransformControls(
			scale: $scale,
			translation: $translation,
			rotation: $rotation,
			scaleRange: scaleRange,
			translationXRange: translationXRange,
			translationYRange: translationYRange,
			rotationRange: rotationRange,
			scaleSensivity: scaleSensivity,
			translationXSensivity: translationXSensivity,
			translationYSensivity: translationYSensivity,
			rotationSensivity: rotationSensivity,
			isFineMode: isFineMode
		)
	}

	var fisheyeControls: some View {
		RTSPFisheyeControls(
			fisheyeCorrection: $fisheyeCorrection,
			fisheyeRange: fisheyeRange,
			fisheyeSensivity: fisheyeSensivity,
			isFineMode: isFineMode
		)
	}

	// MARK: - Header bar (tabs + close)

	var headerBar: some View {
		HStack(spacing: 10) {
#if os(tvOS)
			tabPill
#else
			if hasFisheye || hasCameras {
				tabPicker
			}
#endif
			Spacer(minLength: 0)
			// tvOS has no pointer to tap a close button, and a focusable one steals
			// the upward swipe off the controls. There the panel is dismissed with
			// the remote's Menu/back button instead (see `onExitCommand`).
#if !os(tvOS)
			Button(
				String(localized: "transform.close", bundle: .module),
				systemImage: "xmark",
				action: closeAction
			)
			.labelStyle(.iconOnly)
			.controlSize(.small)
#endif
		}
		.padding()
	}

#if os(tvOS)
	var tabPill: some View {
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
		.padding(.vertical, 2)
		.background(
			Capsule(style: .continuous)
				.fill(Color.primary.opacity(0.10))
		)
	}

	@ViewBuilder
	private func tabButton(_ tab: Tab, systemImage: String, label: String) -> some View {
		let isActive = (selectedTab == tab)
		let isFocus = (focusedTab == tab)
		Image(systemName: systemImage)
			.font(.body)
			.fontWeight(isFocus || isActive ? .semibold : .regular)
			.foregroundStyle(
				isFocus
					? Color.black
					: (isActive ? Color.primary : Color.primary.opacity(0.6))
			)
			.frame(width: 24, height: 20)
			.padding(.vertical, 14)
			.padding(.horizontal, 32)
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
			.focusable(true)
			.focused($focusedTab, equals: tab)
	}
#else
	var tabPicker: some View {
		Picker(selection: $selectedTab) {
			Text(String(localized: "transform.tab.transform", bundle: .module))
				.tag(Tab.transform)
			if hasFisheye {
				Text(String(localized: "transform.tab.fisheye", bundle: .module))
					.tag(Tab.fisheye)
			}
			if hasCameras {
				Text(String(localized: "transform.tab.cameras", bundle: .module))
					.tag(Tab.cameras)
			}
		} label: {
			EmptyView()
		}
		.pickerStyle(.segmented)
		.labelsHidden()
		.fixedSize()
	}
#endif

	// MARK: - Footer

	var footer: some View {
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

#if os(tvOS)
			Button(String(localized: "transform.fine", bundle: .module)) {
				isFineMode.toggle()
			}
			.foregroundStyle(isFineMode ? Color.panelAccent : .primary)
			.font(isFineMode ? .body.bold() : .body)
#endif
		}
		.padding()
	}

	// MARK: - Panel background

	var panelBackground: some View {
		RoundedRectangle(cornerRadius: 18, style: .continuous)
#if os(tvOS)
			// Custom semi-transparent surface — no system blur, so the video shows
			// crisply behind the panel. Adaptive low-opacity veil keeps text legible.
			.fill(Color.panelSurface)
#else
			// Standard system material, as a native overlay panel would use.
			.fill(.regularMaterial)
#endif
			.overlay(
				RoundedRectangle(cornerRadius: 18, style: .continuous)
					.strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
			)
			.shadow(color: .black.opacity(0.22), radius: 14, y: 6)
	}
}

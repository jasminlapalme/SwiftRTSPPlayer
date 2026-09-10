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
/// rotation) — and optionally fisheye correction, a mask and camera selection —
/// through tabs. On iOS and macOS the tabs use native controls (sliders, numeric
/// fields, segmented tabs); on tvOS they use a focus-driven, swipe-based UI.
/// The library ships the control; the client decides if/where to show it —
/// typically as an `.overlay` on `RTSPPlayerView`.
///
/// The tabs' contents are also public views — `RTSPTransformControls`,
/// `RTSPFisheyeControls`, `RTSPMaskControls` and `RTSPCameraListView` — for
/// clients that want to compose their own panel instead.
///
/// ```swift
/// RTSPPlayerView(url: url, rotation: $rotation, scale: $scale, translation: $translation)
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
	@Binding private var mask: VideoMask

	private let hasFisheye: Bool
	private let hasMask: Bool
	private let scaleRange: ClosedRange<CGFloat>
	private let translationXRange: ClosedRange<CGFloat>
	private let translationYRange: ClosedRange<CGFloat>
	private let rotationRange: ClosedRange<CGFloat>
	private let fisheyeRange: ClosedRange<CGFloat>
	private let maskRange: ClosedRange<CGFloat>

	private let defaultScale: CGFloat
	private let defaultTranslation: CGPoint
	private let defaultRotation: CGFloat
	private let defaultFisheye: FisheyeCorrection
	private let defaultMask: VideoMask

	private let scaleSensivity: CGFloat
	private let translationXSensivity: CGFloat
	private let translationYSensivity: CGFloat
	private let rotationSensivity: CGFloat
	private let fisheyeSensivity: CGFloat
	private let maskSensivity: CGFloat

	private let closeAction: () -> Void
	private let cameraURL: Binding<RTSPCameraSelection?>?
	private let managedCredentials: [RTSPManagedCredentials]

	/// Fine mode is a tvOS affordance: it shrinks the remote's adjustment step.
	/// The native sliders elsewhere position absolutely, so the state stays
	/// `false` there and the toggle is not shown.
	@State private var isFineMode: Bool = false
	@State private var selectedTab: Tab = .transform
	/// Guards the reset button: the adjustments it discards can be long to redo.
	@State private var isConfirmingReset = false
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
		case transform, fisheye, mask, cameras
	}

	public init(
		scale: Binding<CGFloat>,
		translation: Binding<CGPoint>,
		rotation: Binding<CGFloat>,
		fisheyeCorrection: Binding<FisheyeCorrection>? = nil,
		mask: Binding<VideoMask>? = nil,
		scaleRange: ClosedRange<CGFloat> = 0.1...3.0,
		translationXRange: ClosedRange<CGFloat> = -500...500,
		translationYRange: ClosedRange<CGFloat> = -500...500,
		rotationRange: ClosedRange<CGFloat> = -180...180,
		fisheyeRange: ClosedRange<CGFloat> = -1...1,
		maskRange: ClosedRange<CGFloat> = 0...0.45,
		defaultScale: CGFloat = 1.0,
		defaultTranslation: CGPoint = .zero,
		defaultRotation: CGFloat = 0,
		defaultFisheye: FisheyeCorrection = .identity,
		defaultMask: VideoMask = .identity,
		scaleSensivity: CGFloat = 0.1,
		translationXSensivity: CGFloat = 10.0,
		translationYSensivity: CGFloat = 10.0,
		rotationSensivity: CGFloat = 1.0,
		fisheyeSensivity: CGFloat = 0.05,
		maskSensivity: CGFloat = 0.05,
		closeAction: @escaping () -> Void = {},
		cameraURL: Binding<RTSPCameraSelection?>? = nil,
		managedCredentials: [RTSPManagedCredentials] = []
	) {
		self._scale = scale
		self._translation = translation
		self._rotation = rotation
		self._fisheyeCorrection = fisheyeCorrection ?? .constant(.identity)
		self.hasFisheye = fisheyeCorrection != nil
		self._mask = mask ?? .constant(.identity)
		self.hasMask = mask != nil
		self.scaleRange = scaleRange
		self.translationXRange = translationXRange
		self.translationYRange = translationYRange
		self.rotationRange = rotationRange
		self.fisheyeRange = fisheyeRange
		self.maskRange = maskRange
		self.defaultScale = defaultScale
		self.defaultTranslation = defaultTranslation
		self.defaultRotation = defaultRotation
		self.defaultFisheye = defaultFisheye
		self.defaultMask = defaultMask
		self.scaleSensivity = scaleSensivity
		self.translationXSensivity = translationXSensivity
		self.translationYSensivity = translationYSensivity
		self.rotationSensivity = rotationSensivity
		self.fisheyeSensivity = fisheyeSensivity
		self.maskSensivity = maskSensivity
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
		case .mask:
			return hasMask ? .mask : .transform
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
			case .mask:
				fixedTab { maskControls }
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
	/// together lets us measure that combined height and mirror it onto every
	/// other tab — the mask tab carries an extra row, and the cameras tab has no
	/// footer, so left alone the panel would resize as they are switched.
	@ViewBuilder
	private func fixedTab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			content()
			footer
		}
		// A floor, not a height: the measurement below then reports the tallest
		// tab seen so far, which settles once every tab has been shown.
		.frame(minHeight: fixedTabHeight, alignment: .top)
		.background(
			GeometryReader { proxy in
				Color.clear.preference(key: FixedTabHeightKey.self, value: proxy.size.height)
			}
		)
	}

	// MARK: - Reset

	/// Resets the tab on show, so one long-tuned setting is never lost with
	/// another.
	private func resetAll() {
		switch effectiveTab {
		case .fisheye:
			fisheyeCorrection = defaultFisheye
		case .mask:
			mask = defaultMask
		case .transform, .cameras:
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

	var maskControls: some View {
		RTSPMaskControls(
			mask: $mask,
			maskRange: maskRange,
			maskSensivity: maskSensivity,
			isFineMode: isFineMode
		)
	}

	// MARK: - Header bar (tabs + close)

	/// The tabs on offer, in order — a tab whose feature the client left out is
	/// simply absent.
	private var tabItems: [PanelTabBar<Tab>.Item] {
		var items: [PanelTabBar<Tab>.Item] = [
			.init(
				tab: .transform,
				systemImage: "crop.rotate",
				label: String(localized: "transform.tab.transform", bundle: .module)
			)
		]
		if hasFisheye {
			items.append(.init(
				tab: .fisheye,
				systemImage: "camera.aperture",
				label: String(localized: "transform.tab.fisheye", bundle: .module)
			))
		}
		if hasMask {
			items.append(.init(
				tab: .mask,
				systemImage: "rectangle.inset.filled",
				label: String(localized: "transform.tab.mask", bundle: .module)
			))
		}
		if hasCameras {
			items.append(.init(
				tab: .cameras,
				systemImage: "video",
				label: String(localized: "transform.tab.cameras", bundle: .module)
			))
		}
		return items
	}

	var headerBar: some View {
		HStack(spacing: 10) {
#if os(tvOS)
			PanelTabBar(items: tabItems, selection: $selectedTab, focusedTab: $focusedTab)
#else
			if tabItems.count > 1 {
				PanelTabBar(items: tabItems, selection: $selectedTab)
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

	// MARK: - Footer

	var footer: some View {
		HStack {
#if os(tvOS)
			Button {
				isFineMode.toggle()
			} label: {
				Label(
					String(localized: "transform.fine", bundle: .module),
					systemImage: "plusminus"
				)
				// Two points taller than the reset button: moving down, the focus engine
				// takes the candidate whose top edge is the closest.
				.padding(.vertical, 2)
			}
			.foregroundStyle(isFineMode ? Color.panelAccent : .primary)
			.font(isFineMode ? .body.bold() : .body)
#endif

			Spacer()

			Button {
				isConfirmingReset = true
			} label: {
				Label(
					String(localized: "transform.allDefaults", bundle: .module),
					systemImage: "arrow.counterclockwise"
				)
			}
			.confirmationDialog(
				String(localized: "transform.allDefaults.confirmTitle", bundle: .module),
				isPresented: $isConfirmingReset,
				titleVisibility: .visible
			) {
				Button(
					String(localized: "transform.allDefaults.confirmAction", bundle: .module),
					role: .destructive,
					action: resetAll
				)
				Button(String(localized: "transform.cancel", bundle: .module), role: .cancel) {}
			} message: {
				Text(String(localized: "transform.allDefaults.confirmMessage", bundle: .module))
			}
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

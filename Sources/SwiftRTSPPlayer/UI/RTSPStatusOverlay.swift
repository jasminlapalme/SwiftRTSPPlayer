//
//  RTSPStatusOverlay.swift
//  SwiftRTSPPlayer
//

import SwiftUI

/// Builds the view a player lays over its video to report playback state.
public typealias RTSPStatusOverlayBuilder = @MainActor (RTSPPlaybackState) -> AnyView

extension EnvironmentValues {
	/// How `RTSPPlayerView` presents its playback state. The built-in banner by
	/// default; ``SwiftUI/View/rtspStatusOverlay(_:)`` replaces it.
	@Entry public var rtspStatusOverlay: RTSPStatusOverlayBuilder = { state in
		AnyView(RTSPPlaybackStatusOverlay(state: state))
	}
}

extension View {
	/// Replaces the built-in status banner of every `RTSPPlayerView` below this
	/// one. The player keeps owning the state and hands it to `content`, which
	/// is free to word, style, place or transform the message — for a host whose
	/// own presentation the library's banner cannot match.
	///
	/// ```swift
	/// CameraGrid()
	///     .rtspStatusOverlay { state in StatusBanner(state: state) }
	/// ```
	///
	/// The view is laid over the whole player, so it decides its own alignment.
	/// Return `EmptyView()` for a state that should show nothing.
	public func rtspStatusOverlay<Content: View>(
		@ViewBuilder _ content: @escaping @MainActor (RTSPPlaybackState) -> Content
	) -> some View {
		environment(\.rtspStatusOverlay) { state in AnyView(content(state)) }
	}
}

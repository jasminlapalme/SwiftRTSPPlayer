//
//  RTSPStatusOverlay.swift
//  SwiftRTSPPlayer
//

import SwiftUI

/// Builds the view a player lays over its video, as a value so SwiftUI can tell it has
/// not changed. Return `EmptyView()` for a state that should show nothing.
public protocol RTSPStatusOverlayStyle: Sendable {
	associatedtype Body: View

	@MainActor @ViewBuilder func makeBody(state: RTSPPlaybackState) -> Body
}

/// The library's own banner, used when no other style is set.
public struct DefaultRTSPStatusOverlayStyle: RTSPStatusOverlayStyle {
	public init() {}

	public func makeBody(state: RTSPPlaybackState) -> some View {
		RTSPPlaybackStatusOverlay(state: state)
	}
}

extension RTSPStatusOverlayStyle {
	@MainActor func anyBody(state: RTSPPlaybackState) -> AnyView {
		AnyView(makeBody(state: state))
	}
}

extension EnvironmentValues {
	/// How `RTSPPlayerView` presents its playback state; set it with
	/// ``SwiftUI/View/rtspStatusOverlayStyle(_:)``.
	@Entry public var rtspStatusOverlayStyle: any RTSPStatusOverlayStyle = DefaultRTSPStatusOverlayStyle()
}

extension View {
	/// Replaces the built-in status banner of every `RTSPPlayerView` below this one,
	/// for a host whose own presentation the library's banner cannot match.
	public func rtspStatusOverlayStyle(_ style: some RTSPStatusOverlayStyle) -> some View {
		environment(\.rtspStatusOverlayStyle, style)
	}
}

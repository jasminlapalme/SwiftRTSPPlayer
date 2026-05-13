//
//  RTSPPlayerView.swift
//  LecteurRTSP
//
//  Created by Jasmin Lapalme on 2026-03-30.
//

import SwiftUI

public struct RTSPPlayerView: View {
	public let url: URL
	public var rotation: CGFloat
	public var scale: CGFloat
	public var translation: CGPoint
	public var fisheyeCorrection: FisheyeCorrection

	@State private var playbackState: RTSPPlaybackState = .stopped

	public init(
		url: URL,
		rotation: CGFloat = 0,
		scale: CGFloat = 1.0,
		translation: CGPoint = .zero,
		fisheyeCorrection: FisheyeCorrection = .identity
	) {
		self.url = url
		self.rotation = rotation
		self.scale = scale
		self.translation = translation
		self.fisheyeCorrection = fisheyeCorrection
	}

	public var body: some View {
		RTSPPlatformPlayerView(
			url: url,
			rotation: rotation,
			scale: scale,
			translation: translation,
			fisheyeCorrection: fisheyeCorrection,
			playbackState: $playbackState
		)
		.overlay {
			RTSPPlaybackStatusOverlay(state: playbackState)
		}
	}
}

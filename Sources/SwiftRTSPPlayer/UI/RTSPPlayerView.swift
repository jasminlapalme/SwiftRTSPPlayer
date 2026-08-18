//
//  RTSPPlayerView.swift
//  LecteurRTSP
//
//  Created by Jasmin Lapalme on 2026-03-30.
//

import SwiftUI

public struct RTSPPlayerView: View {
	public let url: URL?
	public var fisheyeCorrection: FisheyeCorrection

	@Binding private var rotation: CGFloat
	@Binding private var scale: CGFloat
	@Binding private var translation: CGPoint

	private let interaction: RTSPVideoInteraction
	private let transformLimits: RTSPTransformLimits

	@State private var playbackState: RTSPPlaybackState = .stopped
	@Environment(\.rtspStatusOverlay) private var statusOverlay

	/// Plays with a fixed framing. Gestures on the video are off: with nothing to
	/// write the new values back to, the image would snap back on the next update.
	public init(
		url: URL?,
		rotation: CGFloat = 0,
		scale: CGFloat = 1.0,
		translation: CGPoint = .zero,
		fisheyeCorrection: FisheyeCorrection = .identity
	) {
		self.url = url
		self._rotation = .constant(rotation)
		self._scale = .constant(scale)
		self._translation = .constant(translation)
		self.fisheyeCorrection = fisheyeCorrection
		self.interaction = []
		self.transformLimits = .default
	}

	/// Plays with a framing the viewer can adjust on the video itself — dragging
	/// to move it, pinching or Option-scrolling to zoom around the pointer,
	/// two-finger rotating to turn it. Each gesture writes to its binding, so the
	/// same state drives `RTSPTransformControlPanel` if one is shown.
	///
	/// ```swift
	/// RTSPPlayerView(url: url, rotation: $rotation, scale: $scale, translation: $translation)
	/// ```
	///
	/// - Parameters:
	///   - interaction: which gestures to accept; `[]` matches the fixed-framing
	///     initializer. Ignored on tvOS, which has no pointer.
	///   - transformLimits: how far the gestures may go. Keep these in step with
	///     the ranges given to the control panel.
	public init(
		url: URL?,
		rotation: Binding<CGFloat>,
		scale: Binding<CGFloat>,
		translation: Binding<CGPoint>,
		fisheyeCorrection: FisheyeCorrection = .identity,
		interaction: RTSPVideoInteraction = .all,
		transformLimits: RTSPTransformLimits = .default
	) {
		self.url = url
		self._rotation = rotation
		self._scale = scale
		self._translation = translation
		self.fisheyeCorrection = fisheyeCorrection
		self.interaction = interaction
		self.transformLimits = transformLimits
	}

	public var body: some View {
		Group {
			if let url {
				RTSPPlatformPlayerView(
					url: url,
					rotation: rotation,
					scale: scale,
					translation: translation,
					fisheyeCorrection: fisheyeCorrection,
					interaction: interaction,
					transformLimits: transformLimits,
					onTransformChange: applyGestureTransform,
					playbackState: $playbackState
				)
			} else {
				Color.clear
			}
		}
		.overlay {
			statusOverlay(url == nil ? .noSource : playbackState)
		}
	}

	private func applyGestureTransform(_ transform: RTSPTransform) {
		rotation = transform.rotation
		scale = transform.scale
		translation = transform.translation
	}
}

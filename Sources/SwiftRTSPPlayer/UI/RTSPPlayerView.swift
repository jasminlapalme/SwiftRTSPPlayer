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
	public var perspective: VideoPerspective
	public var mask: VideoMask

	@Binding private var rotation: CGFloat
	@Binding private var scale: CGFloat
	@Binding private var translation: CGPoint

	private let interaction: RTSPVideoInteraction
	private let transformLimits: RTSPTransformLimits
	private var pictureHandler: RTSPPictureHandler?
	private var pictureInterval: Duration = .zero
	private var editedPerspective: Binding<VideoPerspective>?
	private var isPerspectiveEditorActive = false

	@State private var playbackState: RTSPPlaybackState = .stopped
	@State private var videoSize: CGSize?
	@Environment(\.rtspStatusOverlayStyle) private var statusOverlayStyle

	/// Plays with a fixed framing. Gestures on the video are off: with nothing to
	/// write the new values back to, the image would snap back on the next update.
	public init(
		url: URL?,
		rotation: CGFloat = 0,
		scale: CGFloat = 1.0,
		translation: CGPoint = .zero,
		fisheyeCorrection: FisheyeCorrection = .identity,
		perspective: VideoPerspective = .identity,
		mask: VideoMask = .identity
	) {
		self.url = url
		self._rotation = .constant(rotation)
		self._scale = .constant(scale)
		self._translation = .constant(translation)
		self.fisheyeCorrection = fisheyeCorrection
		self.perspective = perspective
		self.mask = mask
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
		perspective: VideoPerspective = .identity,
		mask: VideoMask = .identity,
		interaction: RTSPVideoInteraction = .all,
		transformLimits: RTSPTransformLimits = .default
	) {
		self.url = url
		self._rotation = rotation
		self._scale = scale
		self._translation = translation
		self.fisheyeCorrection = fisheyeCorrection
		self.perspective = perspective
		self.mask = mask
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
					perspective: editedPerspective?.wrappedValue ?? perspective,
					isEditingPerspective: showsPerspectiveHandles,
					mask: mask,
					interaction: interaction,
					transformLimits: transformLimits,
					onTransformChange: applyGestureTransform,
					onVideoSizeChange: { videoSize = $0 },
					pictureHandler: pictureHandler,
					pictureInterval: pictureInterval,
					playbackState: $playbackState
				)
			} else {
				Color.clear
			}
		}
		.overlay {
			perspectiveHandles
		}
		.overlay {
			statusOverlayStyle.anyBody(state: url == nil ? .noSource : playbackState)
		}
	}

	/// tvOS has no pointer for the handles, so its picture stays straightened while the panel edits it.
	private var showsPerspectiveHandles: Bool {
#if os(tvOS)
		false
#else
		isPerspectiveEditorActive && editedPerspective != nil
#endif
	}

	@ViewBuilder
	private var perspectiveHandles: some View {
#if !os(tvOS)
		if showsPerspectiveHandles, url != nil, let editedPerspective, let videoSize {
			RTSPPerspectiveHandles(perspective: editedPerspective, videoSize: videoSize)
		}
#endif
	}

	/// Takes over the initializer's perspective; while `isActive`, its corners are dragged over the unframed picture.
	public func perspectiveEditing(_ perspective: Binding<VideoPerspective>, isActive: Bool) -> RTSPPlayerView {
		var view = self
		view.editedPerspective = perspective
		view.isPerspectiveEditorActive = isActive
		return view
	}

	/// Hands each picture, before fisheye correction, perspective, mask and framing, to `handler`
	/// off the main actor; a slow handler skips to the newest picture.
	public func onPicture(
		minimumInterval: Duration = .zero,
		perform handler: @escaping RTSPPictureHandler
	) -> RTSPPlayerView {
		var view = self
		view.pictureHandler = handler
		view.pictureInterval = minimumInterval
		return view
	}

	private func applyGestureTransform(_ transform: RTSPTransform) {
		rotation = transform.rotation
		scale = transform.scale
		translation = transform.translation
	}
}

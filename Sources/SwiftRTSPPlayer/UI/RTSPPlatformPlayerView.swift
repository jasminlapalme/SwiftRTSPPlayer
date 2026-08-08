//
//  RTSPPlatformPlayerView.swift
//  SwiftRTSPPlayer
//

import SwiftUI

#if os(tvOS) || os(iOS) || os(visionOS)

struct RTSPPlatformPlayerView: UIViewRepresentable {
	let url: URL
	let rotation: CGFloat
	let scale: CGFloat
	let translation: CGPoint
	let fisheyeCorrection: FisheyeCorrection
	let interaction: RTSPVideoInteraction
	let transformLimits: RTSPTransformLimits
	let onTransformChange: (RTSPTransform) -> Void
	@Binding var playbackState: RTSPPlaybackState

	func makeCoordinator() -> RTSPPlayerCoordinator {
		RTSPPlayerCoordinator(playbackState: $playbackState)
	}

	func makeUIView(context: Context) -> RTSPMetalView {
		let view = RTSPMetalView()
		context.coordinator.bind(view)
		context.coordinator.currentURL = url
		applyConfiguration(to: view)
		context.coordinator.play(view, url: url)
		return view
	}

	func updateUIView(_ uiView: RTSPMetalView, context: Context) {
		context.coordinator.playbackState = $playbackState
		applyConfiguration(to: uiView)

		if context.coordinator.currentURL != url {
			context.coordinator.currentURL = url
			context.coordinator.play(uiView, url: url)
		}
	}

	static func dismantleUIView(_ uiView: RTSPMetalView, coordinator: RTSPPlayerCoordinator) {
		coordinator.stopObservingPlaybackState()
		uiView.onTransformChange = nil
		uiView.stop()
	}

	private func applyConfiguration(to view: RTSPMetalView) {
		view.rotation = rotation
		view.scale = scale
		view.translation = translation
		view.fisheyeCorrection = fisheyeCorrection
		view.interaction = interaction
		view.transformLimits = transformLimits
		view.onTransformChange = onTransformChange
	}
}

#else

struct RTSPPlatformPlayerView: NSViewRepresentable {
	let url: URL
	let rotation: CGFloat
	let scale: CGFloat
	let translation: CGPoint
	let fisheyeCorrection: FisheyeCorrection
	let interaction: RTSPVideoInteraction
	let transformLimits: RTSPTransformLimits
	let onTransformChange: (RTSPTransform) -> Void
	@Binding var playbackState: RTSPPlaybackState

	func makeCoordinator() -> RTSPPlayerCoordinator {
		RTSPPlayerCoordinator(playbackState: $playbackState)
	}

	func makeNSView(context: Context) -> RTSPMetalView {
		let view = RTSPMetalView()
		context.coordinator.bind(view)
		context.coordinator.currentURL = url
		applyConfiguration(to: view)
		context.coordinator.play(view, url: url)
		return view
	}

	func updateNSView(_ nsView: RTSPMetalView, context: Context) {
		context.coordinator.playbackState = $playbackState
		applyConfiguration(to: nsView)

		if context.coordinator.currentURL != url {
			context.coordinator.currentURL = url
			context.coordinator.play(nsView, url: url)
		}
	}

	static func dismantleNSView(_ nsView: RTSPMetalView, coordinator: RTSPPlayerCoordinator) {
		coordinator.stopObservingPlaybackState()
		nsView.onTransformChange = nil
		nsView.stop()
	}

	private func applyConfiguration(to view: RTSPMetalView) {
		view.rotation = rotation
		view.scale = scale
		view.translation = translation
		view.fisheyeCorrection = fisheyeCorrection
		view.interaction = interaction
		view.transformLimits = transformLimits
		view.onTransformChange = onTransformChange
	}
}

#endif

//
//  RTSPPlayerCoordinator.swift
//  SwiftRTSPPlayer
//

import SwiftUI

final class RTSPPlayerCoordinator {
	var playbackState: Binding<RTSPPlaybackState>
	var currentURL: URL?
	private var playbackStateTask: Task<Void, Never>?

	init(playbackState: Binding<RTSPPlaybackState>) {
		self.playbackState = playbackState
	}

	@MainActor
	func bind(_ view: RTSPMetalView) {
		// Cancel any prior observation: re-binding (e.g. when the SwiftUI view
		// is re-created with a different RTSPMetalView) must replace the
		// observation, not be silently dropped.
		playbackStateTask?.cancel()
		playbackStateTask = Task { [weak self] in
			for await state in view.playbackStates {
				guard !Task.isCancelled else { return }
				self?.playbackState.wrappedValue = state
			}
		}
	}

	func play(_ view: RTSPMetalView, url: URL) {
		Task { @MainActor in
			view.play(url: url)
		}
	}

	func stopObservingPlaybackState() {
		playbackStateTask?.cancel()
		playbackStateTask = nil
	}
}

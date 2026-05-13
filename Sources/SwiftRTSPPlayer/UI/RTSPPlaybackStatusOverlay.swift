//
//  RTSPPlaybackStatusOverlay.swift
//  SwiftRTSPPlayer
//

import SwiftUI

struct RTSPPlaybackStatusOverlay: View {
	let state: RTSPPlaybackState

	private struct Content {
		let message: String
		let systemImage: String
		let showsProgress: Bool
	}

	var body: some View {
		if let content {
			HStack(spacing: 10) {
				if content.showsProgress {
					ProgressView()
						.controlSize(.small)
				} else {
					Image(systemName: content.systemImage)
						.imageScale(.medium)
				}

				Text(content.message)
					.font(.callout.weight(.medium))
					.lineLimit(2)
					.multilineTextAlignment(.leading)
			}
			.padding()
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
			.shadow(color: .black.opacity(0.18), radius: 12, y: 5)
			.padding(16)
			.transition(.opacity.combined(with: .scale(scale: 0.97)))
			.animation(.easeInOut(duration: 0.18), value: state)
		}
	}

	private var content: Content? {
		switch state {
		case .connecting:
			return Content(
				message: String(localized: "playback.connecting", bundle: .module),
				systemImage: "antenna.radiowaves.left.and.right",
				showsProgress: true
			)
		case .failed(let message):
			return Content(message: message, systemImage: "exclamationmark.triangle", showsProgress: false)
		case .playing, .stopped:
			return nil
		}
	}
}

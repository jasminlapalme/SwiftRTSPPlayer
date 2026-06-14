//
//  RTSPTransformControlPanel+Previews.swift
//  SwiftRTSPPlayer
//

import SwiftUI

private struct PreviewBackdrop: View {
	var body: some View {
		// Mimic video content with bands of different luminance so we can
		// visually validate panel readability against both bright and dark
		// regions in either color scheme.
		LinearGradient(
			colors: [
				Color(red: 0.95, green: 0.93, blue: 0.88),
				Color(red: 0.18, green: 0.34, blue: 0.55),
				Color(red: 0.05, green: 0.07, blue: 0.10)
			],
			startPoint: .topLeading,
			endPoint: .bottomTrailing
		)
		.ignoresSafeArea()
	}
}

#Preview("Light mode") {
	@Previewable @State var scale: CGFloat = 1.2
	@Previewable @State var translation: CGPoint = CGPoint(x: 30, y: -10)
	@Previewable @State var rotation: CGFloat = 0

	ZStack {
		PreviewBackdrop()
		VStack {
			Spacer()
			RTSPTransformControlPanel(
				scale: $scale,
				translation: $translation,
				rotation: $rotation
			)
			.padding()
		}
	}
	.preferredColorScheme(.light)
}

#Preview("Dark mode") {
	@Previewable @State var scale: CGFloat = 1.2
	@Previewable @State var translation: CGPoint = CGPoint(x: 30, y: -10)
	@Previewable @State var rotation: CGFloat = 0

	ZStack {
		PreviewBackdrop()
		VStack {
			Spacer()
			RTSPTransformControlPanel(
				scale: $scale,
				translation: $translation,
				rotation: $rotation
			)
			.padding()
		}
	}
	.preferredColorScheme(.dark)
}

#Preview("With fisheye") {
	@Previewable @State var scale: CGFloat = 1.0
	@Previewable @State var translation: CGPoint = .zero
	@Previewable @State var rotation: CGFloat = 0
	@Previewable @State var fisheye: FisheyeCorrection = .identity

	ZStack {
		PreviewBackdrop()
		VStack {
			Spacer()
			RTSPTransformControlPanel(
				scale: $scale,
				translation: $translation,
				rotation: $rotation,
				fisheyeCorrection: $fisheye
			)
			.padding()
		}
	}
	.preferredColorScheme(.light)
}

#Preview("With cameras") {
	@Previewable @State var scale: CGFloat = 1.0
	@Previewable @State var translation: CGPoint = .zero
	@Previewable @State var rotation: CGFloat = 0
	@Previewable @State var fisheye: FisheyeCorrection = .identity
	@Previewable @State var cameraURL = URL(string: "rtsp://192.168.1.30/stream")!

	ZStack {
		PreviewBackdrop()
		VStack {
			Spacer()
			RTSPTransformControlPanel(
				scale: $scale,
				translation: $translation,
				rotation: $rotation,
				fisheyeCorrection: $fisheye,
				cameraURL: $cameraURL
			)
			.padding()
		}
	}
	.preferredColorScheme(.dark)
}

#Preview("With fisheye (dark)") {
	@Previewable @State var scale: CGFloat = 1.0
	@Previewable @State var translation: CGPoint = .zero
	@Previewable @State var rotation: CGFloat = 0
	@Previewable @State var fisheye: FisheyeCorrection = .identity

	ZStack {
		PreviewBackdrop()
		VStack {
			Spacer()
			RTSPTransformControlPanel(
				scale: $scale,
				translation: $translation,
				rotation: $rotation,
				fisheyeCorrection: $fisheye
			)
			.padding()
		}
	}
	.preferredColorScheme(.dark)
}

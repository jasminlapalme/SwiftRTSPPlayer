//
//  ContentView.swift
//  DemoSwiftRTSPPlayer
//
//  Created by Jasmin Lapalme on 2026-04-10.
//

import SwiftUI
import SwiftRTSPPlayer

// Set `RTSP_URL` in the Xcode scheme's Environment Variables to point at a
// real camera (Run scheme → Arguments → Environment Variables). The scheme
// lives under `.xcuserdata/` and is not committed, so credentials embedded
// in the URL stay on your machine.
let urls: [URL] = {
	var list: [URL] = [URL(string: "rtsp://localhost:8554/glace_d2")!]
	if let envValue = ProcessInfo.processInfo.environment["RTSP_URL"],
		 let envURL = URL(string: envValue) {
		list.append(envURL)
	}
	return list
}()

// Named credential sets offered in the Cameras tab. Set `RTSP_USERNAME` /
// `RTSP_PASSWORD` in the scheme's Environment Variables to try a real camera's
// login without embedding it in the source.
let managedCredentials: [RTSPManagedCredentials] = {
	let env = ProcessInfo.processInfo.environment
	guard let username = env["RTSP_USERNAME"], let password = env["RTSP_PASSWORD"] else { return [] }
	return [RTSPManagedCredentials(name: "Camera login", username: username, password: password)]
}()

struct ContentView: View {
	@State private var rotation: CGFloat = 0
	@State private var echelle: CGFloat = 1.0
	@State private var translation: CGPoint = .zero
	@State private var currentCamera: RTSPCameraSelection?
	@State private var fisheye: FisheyeCorrection = .identity
	@State private var showsTransformPanel: Bool = true

	/// The URL to actually play. The selection stores a credential-free URL plus
	/// a tag describing how to authenticate it; resolving a managed reference back
	/// to real credentials is the host's job, so secrets stay out of the selection.
	private var playbackURL: URL? {
		currentCamera?.authenticatedURL(managedCredentials: managedCredentials)
	}

	var body: some View {
		VStack {
			// Bindings rather than plain values, so dragging, pinching and
			// Option-scrolling on the video write back here — and the panel's
			// sliders follow along.
			RTSPPlayerView(
				url: playbackURL,
				rotation: $rotation,
				scale: $echelle,
				translation: $translation,
				fisheyeCorrection: fisheye
			)
			.border(Color.blue)
			.overlay(alignment: .bottomLeading) {
				if showsTransformPanel {
					RTSPTransformControlPanel(
						scale: $echelle,
						translation: $translation,
						rotation: $rotation,
						fisheyeCorrection: $fisheye,
						cameraURL: $currentCamera,
						managedCredentials: managedCredentials
					)
					.padding()
				}
			}
		}.edgesIgnoringSafeArea(.all)
	}
}

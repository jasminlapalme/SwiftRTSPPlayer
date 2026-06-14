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

struct ContentView: View {
	@State private var rotation: CGFloat = 0
	@State private var echelle: CGFloat = 1.0
	@State private var translation: CGPoint = .zero
	@State private var currentURL = urls[0]
	@State private var fisheye: FisheyeCorrection = .identity
	@State private var showsTransformPanel: Bool = true

	var body: some View {
		VStack {
			RTSPPlayerView(
				url: currentURL,
				rotation: rotation,
				scale: echelle,
				translation: translation,
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
						cameraURL: $currentURL
					)
					.padding()
				}
			}
		}.edgesIgnoringSafeArea(.all)
	}
}

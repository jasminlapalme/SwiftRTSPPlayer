//
//  RTSPMetalView.swift
//  LecteurRTSP
//
//  Created by Jasmin Lapalme on 2026-03-30.
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import MetalKit
import os

private let log = Logger(subsystem: "SwiftRTSPPlayer", category: "RTSPMetalView")

#if os(macOS)
public typealias RTSPPlatformView = NSView
#else
public typealias RTSPPlatformView = UIView
#endif

@MainActor
public final class RTSPMetalView: RTSPPlatformView {

	// MARK: - Metal

	private let metalLayer = CAMetalLayer()
	private var renderer: MetalVideoRenderer?

	// MARK: - Pipeline

	private var task: Task<Void, Never>?
	private var pipeline: RTSPPipeline?
	private var shouldReconnect = false
	private var hasRenderedFrame = false
	private var playbackState: RTSPPlaybackState = .stopped
	private var playbackStateContinuation: AsyncStream<RTSPPlaybackState>.Continuation?
	private var holdsIdleTimer = false

	// MARK: - Reconnection

	// Fixed cadence — surveillance cameras can be offline for arbitrary
	// stretches (network reboot, power blip). Keep retrying at a steady
	// interval rather than backing off exponentially and giving up.
	private static let reconnectDelay: TimeInterval = 5.0

	// MARK: - Video sizing

	private var videoWidth: Int = 1920
	private var videoHeight: Int = 1080

	// MARK: - Transform

	public var rotation: CGFloat = 0 { didSet { applyTransform() } }
	public var scale: CGFloat = 1.0 { didSet { updateMetalLayer() } }
	public var translation: CGPoint = .zero { didSet { applyTransform() } }
	public var fisheyeCorrection: FisheyeCorrection = .identity {
		didSet { renderer?.fisheyeCorrection = fisheyeCorrection }
	}
	public var playbackStates: AsyncStream<RTSPPlaybackState> {
		AsyncStream { continuation in
			playbackStateContinuation = continuation
		}
	}

	// MARK: - Init

	#if os(macOS)
	public override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		setup()
	}
	#else
	public override init(frame: CGRect) {
		super.init(frame: frame)
		setup()
	}
	#endif

	public required init?(coder: NSCoder) {
		super.init(coder: coder)
		setup()
	}

	private func setup() {
		#if os(macOS)
		wantsLayer = true
		layer?.masksToBounds = true
		layer?.addSublayer(metalLayer)
		#else
		layer.addSublayer(metalLayer)
		clipsToBounds = true
		#endif

		metalLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
	}

	// MARK: - Layout

	#if os(macOS)
	public override func layout() {
		super.layout()
		updateMetalLayer()
	}
	#else
	public override func layoutSubviews() {
		super.layoutSubviews()
		updateMetalLayer()
	}
	#endif

	// MARK: - Public API

	public func play(url: URL) {
		acquireIdleTimer()
		connect(url: url)
	}

	public func stop() {
		shouldReconnect = false
		task?.cancel()
		task = nil
		let stoppedPipeline = pipeline
		Task { await stoppedPipeline?.stop() }
		self.pipeline = nil
		hasRenderedFrame = false
		releaseIdleTimer()
		setPlaybackState(.stopped)
	}

	private func acquireIdleTimer() {
		#if os(iOS) || os(tvOS) || os(macOS)
		guard !holdsIdleTimer else { return }
		holdsIdleTimer = true
		IdleTimerCoordinator.acquire()
		#endif
	}

	private func releaseIdleTimer() {
		#if os(iOS) || os(tvOS) || os(macOS)
		guard holdsIdleTimer else { return }
		holdsIdleTimer = false
		IdleTimerCoordinator.release()
		#endif
	}

	// MARK: - Connect / Reconnect

	private func connect(url: URL) {
		// Capture the previous run so the new task can await its full teardown
		// before claiming the shared CAMetalLayer — otherwise the old and new
		// renderers fight over nextDrawable() and the streams visually overlap.
		let previousTask = task
		let previousPipeline = pipeline
		previousTask?.cancel()

		shouldReconnect = true
		hasRenderedFrame = false
		setPlaybackState(.connecting)

		let renderer = MetalVideoRenderer(layer: metalLayer)
		renderer?.fisheyeCorrection = fisheyeCorrection
		self.renderer = renderer

		let pipeline = RTSPPipeline()
		self.pipeline = pipeline

		task = Task { [weak self] in
			await previousPipeline?.stop()
			_ = await previousTask?.value

			guard let self, !Task.isCancelled else { return }

			do {
				let stream = await pipeline.frames(url: url)

				for try await frame in stream {
					if Task.isCancelled { break }
					renderer?.render(pixelBuffer: frame.pixelBuffer)
					if !self.hasRenderedFrame {
						self.hasRenderedFrame = true
						self.setPlaybackState(.playing)
					}
				}

				if Task.isCancelled { return }
				self.task = nil
				self.setPlaybackState(.connecting)
				await self.scheduleReconnect(url: url)

			} catch {
				if Task.isCancelled { return }
				log.error("RTSP pipeline error: \(redactCredentials(in: error.localizedDescription), privacy: .public)")
				self.task = nil
				self.setPlaybackState(.connecting)
				await self.scheduleReconnect(url: url)
			}
		}
	}

	private func scheduleReconnect(url: URL) async {
		// Light jitter to avoid synchronised reconnect bursts when several
		// players reconnect to the same network event.
		let jitter = Double.random(in: 0.85...1.15)
		let delay = Self.reconnectDelay * jitter

		try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

		guard shouldReconnect, task == nil else { return }

		connect(url: url)
	}

	// MARK: - Metal layout

	private func updateMetalLayer() {

		let viewSize = bounds.size
		let videoSize = CGSize(width: videoWidth, height: videoHeight)

		let fitScale = min(
			viewSize.width / videoSize.width,
			viewSize.height / videoSize.height
		)

		let finalScale = fitScale * scale

		let finalSize = CGSize(
			width: videoSize.width * finalScale,
			height: videoSize.height * finalScale
		)

		metalLayer.bounds = CGRect(origin: .zero, size: finalSize)
		metalLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)

		metalLayer.drawableSize = CGSize(
			width: videoSize.width,
			height: videoSize.height
		)

		applyTransform()
	}

	private func applyTransform() {
		let rad = rotation * .pi / 180

		// L'axe Y d'AppKit pointe vers le haut (UIKit : vers le bas). On inverse
		// la translation verticale et le sens de rotation pour qu'une même
		// configuration produise le même cadrage que sur tvOS/iOS (la référence).
		#if os(macOS)
		let translationY = -translation.y
		let angle = -rad
		#else
		let translationY = translation.y
		let angle = rad
		#endif

		var transform = CATransform3DIdentity
		transform = CATransform3DTranslate(transform, translation.x, translationY, 0)
		transform = CATransform3DRotate(transform, angle, 0, 0, 1)

		metalLayer.transform = transform
	}

	private func setPlaybackState(_ state: RTSPPlaybackState) {
		guard playbackState != state else { return }
		playbackState = state
		playbackStateContinuation?.yield(state)
	}
}

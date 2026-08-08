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

	// MARK: - Direct manipulation

	/// Which gestures on the video adjust the transform. Empty by default: the
	/// view only reports the changes, so a host that doesn't carry them back into
	/// its own state would see the framing snap back on the next update.
	public var interaction: RTSPVideoInteraction = []

	/// How far those gestures may push the transform. The translation ranges are
	/// a floor: zoomed in, `gestureLimits` opens them up to the image's edges.
	public var transformLimits: RTSPTransformLimits = .default

	/// What the gestures actually work against — the configured limits, told how
	/// the image currently sits in the view. Read on each step of a gesture, so a
	/// resize or a zoom is taken into account straight away.
	var gestureLimits: RTSPTransformLimits {
		var limits = transformLimits
		limits.layout = RTSPContentLayout(fittedSize: fittedVideoSize, viewSize: bounds.size)
		return limits
	}

	/// Called when a gesture changes the transform — never for a change the host
	/// made itself by setting `scale`, `translation` or `rotation`.
	public var onTransformChange: ((RTSPTransform) -> Void)?

	/// The current framing as one value, the form gestures work in.
	var currentTransform: RTSPTransform {
		RTSPTransform(scale: scale, translation: translation, rotation: rotation)
	}

	/// Applies a gesture's result: the layer follows immediately, and the host
	/// hears about it so its own state — and the control panel — stay in step.
	func applyInteractiveTransform(_ transform: RTSPTransform) {
		guard transform != currentTransform else { return }
		rotation = transform.rotation
		translation = transform.translation
		scale = transform.scale
		onTransformChange?(transform)
	}

#if !os(tvOS)
	private var gestures: RTSPTransformGestureController?
#endif

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

		#if !os(tvOS)
		gestures = RTSPTransformGestureController(view: self)
		#endif
	}

	#if os(macOS)
	/// Scroll to pan, Option-scroll to zoom. Anything the gestures don't claim —
	/// interaction turned off, or a stray zero-delta event — goes on up the
	/// responder chain.
	public override func scrollWheel(with event: NSEvent) {
		if gestures?.handleScroll(event) != true {
			super.scrollWheel(with: event)
		}
	}
	#endif

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

	/// The video's size on screen at scale 1: fitted to the view, aspect kept.
	private var fittedVideoSize: CGSize {
		let videoSize = CGSize(width: videoWidth, height: videoHeight)
		guard videoSize.width > 0, videoSize.height > 0 else { return .zero }
		let fitScale = min(
			bounds.width / videoSize.width,
			bounds.height / videoSize.height
		)
		return CGSize(width: videoSize.width * fitScale, height: videoSize.height * fitScale)
	}

	private func updateMetalLayer() {

		let videoSize = CGSize(width: videoWidth, height: videoHeight)
		let fittedSize = fittedVideoSize

		let finalSize = CGSize(
			width: fittedSize.width * scale,
			height: fittedSize.height * scale
		)

		// The metal layer is a hand-made sublayer, so every geometry change would
		// otherwise run CoreAnimation's default quarter-second implicit animation
		// — which under a drag shows up as the image trailing the pointer.
		CATransaction.begin()
		CATransaction.setDisableActions(true)

		metalLayer.bounds = CGRect(origin: .zero, size: finalSize)
		metalLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)

		metalLayer.drawableSize = CGSize(
			width: videoSize.width,
			height: videoSize.height
		)

		applyTransform()

		CATransaction.commit()
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

		CATransaction.begin()
		CATransaction.setDisableActions(true)
		metalLayer.transform = transform
		CATransaction.commit()
	}

	private func setPlaybackState(_ state: RTSPPlaybackState) {
		guard playbackState != state else { return }
		playbackState = state
		playbackStateContinuation?.yield(state)
	}
}

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

#if os(macOS)
public typealias RTSPPlatformView = NSView
#else
public typealias RTSPPlatformView = UIView
#endif

@MainActor
public final class RTSPMetalView: RTSPPlatformView {

	// MARK: - Metal

	private let metalLayer = CAMetalLayer()
	private let renderer = MetalVideoRenderer()
	/// Kept so a resize or a gesture redraws without waiting for the next
	/// frame: the layer carries no geometry any more.
	private var lastPixelBuffer: CVPixelBuffer?
	private var redrawScheduled = false

	// MARK: - Pipeline

	private var task: Task<Void, Never>?
	private var source: RTSPStreamSource?
	private var playbackState: RTSPPlaybackState = .stopped
	private var playbackStateContinuation: AsyncStream<RTSPPlaybackState>.Continuation?
	private var holdsIdleTimer = false

	// MARK: - Video sizing

	private var videoWidth: Int = 1920
	private var videoHeight: Int = 1080

	// MARK: - Transform

	public var rotation: CGFloat = 0 { didSet { redraw() } }
	public var scale: CGFloat = 1.0 { didSet { redraw() } }
	public var translation: CGPoint = .zero { didSet { redraw() } }
	public var fisheyeCorrection: FisheyeCorrection = .identity { didSet { redraw() } }
	/// Named around `UIView.mask`, which this view would otherwise override.
	public var videoMask: VideoMask = .identity { didSet { redraw() } }

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
		metalLayer.device = renderer?.device
		metalLayer.pixelFormat = .bgra8Unorm
		metalLayer.framebufferOnly = true
		#if os(macOS)
		metalLayer.displaySyncEnabled = true  // vsync on tvOS
		#endif

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

		// Await the previous run's teardown before claiming the shared
		// CAMetalLayer, or the two streams visually overlap.
		let previousTask = task
		let previousSource = source
		previousTask?.cancel()

		let source = RTSPStreamSource(url: url)
		self.source = source
		setPlaybackState(.connecting)

		task = Task { [weak self] in
			await previousSource?.stop()
			_ = await previousTask?.value
			guard let self, !Task.isCancelled else { return }

			for await event in await source.events() {
				if Task.isCancelled { break }
				switch event {
				case .state(let state):
					self.setPlaybackState(state)
				case .picture(let frame):
					self.display(frame.pixelBuffer)
				}
			}
		}
	}

	public func stop() {
		task?.cancel()
		task = nil
		let stoppedSource = source
		source = nil
		Task { await stoppedSource?.stop() }
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

	private func setPlaybackState(_ state: RTSPPlaybackState) {
		guard playbackState != state else { return }
		playbackState = state
		playbackStateContinuation?.yield(state)
	}
}

// MARK: - Metal layout and drawing

extension RTSPMetalView {

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

	/// Pixels per point of the screen the view is on.
	private var backingScale: CGFloat {
		#if os(macOS)
		return window?.backingScaleFactor ?? layer?.contentsScale ?? 1
		#else
		return layer.contentsScale
		#endif
	}

	/// The layer just covers the view at native resolution; the framing is
	/// applied while drawing, as a broadcast composes it.
	private func updateMetalLayer() {
		let scaleFactor = backingScale

		// A hand-made sublayer animates its geometry implicitly, which under a
		// drag shows up as the image trailing the pointer.
		CATransaction.begin()
		CATransaction.setDisableActions(true)

		metalLayer.frame = bounds
		metalLayer.contentsScale = scaleFactor
		let drawableSize = CGSize(
			width: (bounds.width * scaleFactor).rounded(),
			height: (bounds.height * scaleFactor).rounded()
		)
		if drawableSize.width >= 1, drawableSize.height >= 1, metalLayer.drawableSize != drawableSize {
			metalLayer.drawableSize = drawableSize
		}

		CATransaction.commit()

		redraw()
	}

	#if os(macOS)
	/// A screen of a different density changes what a point is worth in pixels.
	public override func viewDidChangeBackingProperties() {
		super.viewDidChangeBackingProperties()
		updateMetalLayer()
	}
	#endif

	// MARK: - Drawing

	/// Shows a newly decoded picture, and remembers it for later redraws.
	private func display(_ pixelBuffer: CVPixelBuffer) {
		lastPixelBuffer = pixelBuffer
		let width = CVPixelBufferGetWidth(pixelBuffer)
		let height = CVPixelBufferGetHeight(pixelBuffer)
		if width > 0, height > 0, width != videoWidth || height != videoHeight {
			videoWidth = width
			videoHeight = height
			// The fitted size feeds the gesture limits, so it follows the camera.
			updateMetalLayer()
			return
		}
		redraw()
	}

	/// At most one redraw per run loop turn: a gesture sets rotation, translation
	/// and scale in a row, and `nextDrawable()` blocks once the queue is full.
	private func redraw() {
		guard !redrawScheduled else { return }
		redrawScheduled = true
		Task { @MainActor [weak self] in
			guard let self else { return }
			self.redrawScheduled = false
			self.drawCurrentPicture()
		}
	}

	/// Draws the current picture with the current framing.
	private func drawCurrentPicture() {
		guard let renderer, let pixelBuffer = lastPixelBuffer else { return }
		let size = metalLayer.drawableSize
		guard size.width >= 1, size.height >= 1,
			let drawable = metalLayer.nextDrawable(),
			let commandBuffer = renderer.makeCommandBuffer()
		else { return }

		let layer = RTSPCompositionLayer(
			pixelBuffer: pixelBuffer,
			frame: CGRect(origin: .zero, size: size),
			scale: scale,
			// The view works in points, a composition in fractions of its frame.
			translation: CGPoint(
				x: bounds.width > 0 ? translation.x / bounds.width : 0,
				y: bounds.height > 0 ? translation.y / bounds.height : 0
			),
			rotation: rotation,
			fisheyeCorrection: fisheyeCorrection,
			mask: videoMask
		)

		renderer.draw([layer], into: drawable.texture, with: commandBuffer)
		commandBuffer.present(drawable)
		commandBuffer.commit()
		renderer.flushTextureCache()
	}
}

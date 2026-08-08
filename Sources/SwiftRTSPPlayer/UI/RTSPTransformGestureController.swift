//
//  RTSPTransformGestureController.swift
//  SwiftRTSPPlayer
//

#if !os(tvOS)

import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Turns pointer and touch gestures on the video into transform updates.
///
/// The recognizers report *cumulative* values, so each continuous gesture is
/// applied to the transform captured when it began rather than accumulated step
/// by step — panning out to a limit and back lands exactly where it started.
///
/// Only `.changed` is acted on, never `.ended`: those cumulative values mean
/// something while the gesture is live and not after. AppKit zeroes
/// `NSRotationGestureRecognizer.rotation` once the turn is over, so reading it
/// there applied "no rotation at all" to the angle the gesture had started
/// from — the image sprang back on release, and again between two segments of a
/// longer turn. The last `.changed` already carries the final value, so the end
/// of a gesture is simply nothing to do.
///
/// Anchors and deltas are handed to `RTSPTransform` in UIKit orientation (y
/// down, origin at the centre of the view); on macOS this controller flips them.
@MainActor
final class RTSPTransformGestureController: NSObject {

	private weak var view: RTSPMetalView?

	/// Read off the view on every step rather than cached: the limits follow the
	/// zoom and the view's size, both of which move under a live gesture.
	private var enabled: RTSPVideoInteraction { view?.interaction ?? [] }
	private var limits: RTSPTransformLimits { view?.gestureLimits ?? .default }

	/// The transform the current gesture started from.
	private var startTransform = RTSPTransform()
	/// Where that gesture started, in centred view coordinates.
	private var startAnchor: CGPoint = .zero

	/// A mouse wheel reports whole lines rather than points; this is what one
	/// line is worth, chosen so a single notch pans about a text line and zooms
	/// by roughly 10%.
	private static let lineHeight: CGFloat = 16
	/// Scroll-to-zoom rate: `e^(points · rate)`, so zooming in and back out over
	/// the same distance returns to the original scale.
	private static let zoomPerScrolledPoint: CGFloat = 0.006

	init(view: RTSPMetalView) {
		self.view = view
		super.init()
		installRecognizers(on: view)
	}

	// MARK: - Shared handling

	/// Snapshots the state a continuous gesture starts from.
	private func beginGesture(anchor: CGPoint) {
		startTransform = view?.currentTransform ?? RTSPTransform()
		startAnchor = anchor
	}

	private func apply(_ transform: RTSPTransform) {
		view?.applyInteractiveTransform(transform)
	}

	/// Re-expresses a point given in the view's own coordinates as an offset from
	/// the view's centre, y pointing down.
	private func centred(_ point: CGPoint) -> CGPoint {
		guard let view else { return .zero }
		#if os(macOS)
		return CGPoint(x: point.x - view.bounds.midX, y: view.bounds.midY - point.y)
		#else
		return CGPoint(x: point.x - view.bounds.midX, y: point.y - view.bounds.midY)
		#endif
	}

	// MARK: - macOS

	#if os(macOS)

	private func installRecognizers(on view: RTSPMetalView) {
		let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
		let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnification(_:)))
		let rotate = NSRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
		for recognizer in [pan, magnify, rotate] as [NSGestureRecognizer] {
			recognizer.delegate = self
			view.addGestureRecognizer(recognizer)
		}
	}

	@objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
		guard enabled.contains(.pan), let view else { return }
		switch gesture.state {
		case .began:
			beginGesture(anchor: centred(gesture.location(in: view)))
		case .changed:
			// AppKit's y points up; the stored translation's points down.
			let moved = gesture.translation(in: view)
			apply(startTransform.panned(by: CGPoint(x: moved.x, y: -moved.y), limits: limits))
		default:
			break
		}
	}

	@objc private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
		guard enabled.contains(.zoom), let view else { return }
		switch gesture.state {
		case .began:
			beginGesture(anchor: centred(gesture.location(in: view)))
		case .changed:
			apply(startTransform.zoomed(by: 1 + gesture.magnification, around: startAnchor, limits: limits))
		default:
			break
		}
	}

	@objc private func handleRotation(_ gesture: NSRotationGestureRecognizer) {
		guard enabled.contains(.rotate), let view else { return }
		switch gesture.state {
		case .began:
			beginGesture(anchor: centred(gesture.location(in: view)))
		case .changed:
			// AppKit measures counterclockwise radians; `rotation` is clockwise degrees.
			apply(startTransform.rotated(by: -gesture.rotation * 180 / .pi, limits: limits))
		default:
			break
		}
	}

	/// Scroll wheel and two-finger scroll: pans, or zooms around the pointer while
	/// Option is held. Returns whether the event was consumed.
	///
	/// Unlike the pan recognizer's translation, scroll deltas already come in
	/// content-follows-the-gesture orientation — a positive `scrollingDeltaY`
	/// moves the content down — so they need no flip.
	func handleScroll(_ event: NSEvent) -> Bool {
		guard let view else { return false }
		let isZoom = event.modifierFlags.contains(.option)
		guard enabled.contains(isZoom ? .zoom : .pan) else { return false }

		let step = event.hasPreciseScrollingDeltas ? 1 : Self.lineHeight
		let deltaX = event.scrollingDeltaX * step
		let deltaY = event.scrollingDeltaY * step
		guard deltaX != 0 || deltaY != 0 else { return false }

		let current = view.currentTransform
		if isZoom {
			let anchor = centred(view.convert(event.locationInWindow, from: nil))
			apply(current.zoomed(by: exp(deltaY * Self.zoomPerScrolledPoint), around: anchor, limits: limits))
		} else {
			apply(current.panned(by: CGPoint(x: deltaX, y: deltaY), limits: limits))
		}
		return true
	}

	// MARK: - iOS / visionOS

	#else

	private func installRecognizers(on view: RTSPMetalView) {
		let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
		// Two fingers still pan, so dragging keeps working through a pinch.
		pan.maximumNumberOfTouches = 2
		let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
		let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
		for recognizer in [pan, pinch, rotate] as [UIGestureRecognizer] {
			recognizer.delegate = self
			view.addGestureRecognizer(recognizer)
		}
	}

	@objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
		guard enabled.contains(.pan), let view else { return }
		switch gesture.state {
		case .began:
			beginGesture(anchor: centred(gesture.location(in: view)))
		case .changed:
			apply(startTransform.panned(by: gesture.translation(in: view), limits: limits))
		default:
			break
		}
	}

	@objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
		guard enabled.contains(.zoom), let view else { return }
		switch gesture.state {
		case .began:
			beginGesture(anchor: centred(gesture.location(in: view)))
		case .changed:
			apply(startTransform.zoomed(by: gesture.scale, around: startAnchor, limits: limits))
		default:
			break
		}
	}

	@objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
		guard enabled.contains(.rotate), let view else { return }
		switch gesture.state {
		case .began:
			beginGesture(anchor: centred(gesture.location(in: view)))
		case .changed:
			apply(startTransform.rotated(by: gesture.rotation * 180 / .pi, limits: limits))
		default:
			break
		}
	}

	#endif
}

// MARK: - Simultaneous recognition

// Pinching, rotating and dragging are one continuous adjustment of the same
// framing; letting them run together is what makes it feel direct.
#if os(macOS)

extension RTSPTransformGestureController: NSGestureRecognizerDelegate {
	nonisolated func gestureRecognizer(
		_ gestureRecognizer: NSGestureRecognizer,
		shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
	) -> Bool {
		true
	}
}

#else

extension RTSPTransformGestureController: UIGestureRecognizerDelegate {
	nonisolated func gestureRecognizer(
		_ gestureRecognizer: UIGestureRecognizer,
		shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
	) -> Bool {
		true
	}
}

#endif

#endif

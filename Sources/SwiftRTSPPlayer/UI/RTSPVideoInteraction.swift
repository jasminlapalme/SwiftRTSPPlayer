//
//  RTSPVideoInteraction.swift
//  SwiftRTSPPlayer
//

import CoreGraphics
import Foundation

/// Which direct-manipulation gestures the player accepts on the video itself.
///
/// | Gesture | macOS | iOS / visionOS |
/// | --- | --- | --- |
/// | `pan` | click-drag, or two-finger scroll | one-finger drag |
/// | `zoom` | trackpad pinch, or Option-scroll | pinch |
/// | `rotate` | trackpad two-finger rotate | two-finger rotate |
///
/// Zooming keeps the point under the pointer (or under the pinch) in place.
/// Unavailable on tvOS, where the remote drives the control panel instead.
public struct RTSPVideoInteraction: OptionSet, Sendable {
	public let rawValue: Int

	public init(rawValue: Int) {
		self.rawValue = rawValue
	}

	public static let pan = RTSPVideoInteraction(rawValue: 1 << 0)
	public static let zoom = RTSPVideoInteraction(rawValue: 1 << 1)
	public static let rotate = RTSPVideoInteraction(rawValue: 1 << 2)

	public static let all: RTSPVideoInteraction = [.pan, .zoom, .rotate]
}

/// The player's framing — scale, translation and rotation — as one value, so a
/// gesture can move several of them at once (zooming around a point changes both
/// the scale and the translation).
public struct RTSPTransform: Equatable, Sendable {
	public var scale: CGFloat
	public var translation: CGPoint
	/// Degrees, clockwise, on every platform.
	public var rotation: CGFloat

	public init(scale: CGFloat = 1.0, translation: CGPoint = .zero, rotation: CGFloat = 0) {
		self.scale = scale
		self.translation = translation
		self.rotation = rotation
	}
}

/// How the image sits in the view, which is what says how far it may be dragged:
/// whatever hangs outside the view has to be reachable.
struct RTSPContentLayout: Equatable, Sendable {
	/// The image's size on screen at scale 1 — the video fitted to the view.
	var fittedSize: CGSize
	/// The size of the view showing it.
	var viewSize: CGSize
}

/// The bounds a gesture keeps the transform within — the same ranges the control
/// panel's sliders use, so both ways of adjusting the framing agree.
public struct RTSPTransformLimits: Equatable, Sendable {
	public var scale: ClosedRange<CGFloat>
	/// The translation ranges are a floor, not a ceiling: zoomed in, they open up
	/// to whatever it takes to reach the image's edges (see `translationRanges`).
	public var translationX: ClosedRange<CGFloat>
	public var translationY: ClosedRange<CGFloat>
	public var rotation: ClosedRange<CGFloat>

	/// Filled in by the player from its own geometry; `nil` leaves the configured
	/// translation ranges as they are.
	var layout: RTSPContentLayout?

	public init(
		scale: ClosedRange<CGFloat> = 0.1...3.0,
		translationX: ClosedRange<CGFloat> = -500...500,
		translationY: ClosedRange<CGFloat> = -500...500,
		rotation: ClosedRange<CGFloat> = -180...180
	) {
		self.scale = scale
		self.translationX = translationX
		self.translationY = translationY
		self.rotation = rotation
	}

	public static let `default` = RTSPTransformLimits()

	/// How far the image may be dragged at a given zoom and angle: the configured
	/// ranges, widened so that every part of the image can be brought into view.
	///
	/// Half the overhang is exactly what it takes — shifting the image by that
	/// much brings its far edge to the edge of the view. Below it the configured
	/// range still applies, so an image smaller than the view can be pushed
	/// around as freely as before.
	func translationRanges(scale: CGFloat, rotation: CGFloat) -> (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) {
		guard let layout, layout.fittedSize.width > 0, layout.fittedSize.height > 0 else {
			return (translationX, translationY)
		}
		let width = layout.fittedSize.width * scale
		let height = layout.fittedSize.height * scale

		// Turned by an angle, what the image takes up on screen is its upright
		// bounding box — wider than the image itself at anything but a quarter turn.
		let radians = rotation * .pi / 180
		let alongX = abs(cos(radians))
		let alongY = abs(sin(radians))
		let spanX = width * alongX + height * alongY
		let spanY = width * alongY + height * alongX

		let overhangX = max(0, (spanX - layout.viewSize.width) / 2)
		let overhangY = max(0, (spanY - layout.viewSize.height) / 2)

		return (
			min(translationX.lowerBound, -overhangX)...max(translationX.upperBound, overhangX),
			min(translationY.lowerBound, -overhangY)...max(translationY.upperBound, overhangY)
		)
	}
}

// MARK: - Gesture arithmetic

/// All of these work in UIKit-oriented view coordinates — x to the right, y
/// *down*, origin at the centre of the view — which is also how `translation` is
/// stored. The AppKit gesture handlers flip y before calling in.
extension RTSPTransform {

	func panned(by delta: CGPoint, limits: RTSPTransformLimits) -> RTSPTransform {
		var moved = self
		moved.translation.x += delta.x
		moved.translation.y += delta.y
		return moved.clamped(to: limits)
	}

	/// Scales by `factor` while pinning `anchor` — the point the pointer or the
	/// pinch sits on — to the image detail already under it.
	///
	/// The rendered position of a detail is `v = R·s·c + t`, so holding `v` fixed
	/// across a scale change `k = s'/s` gives `t' = v - k·(v - t)`. The rotation
	/// drops out, which is why this holds at any angle.
	func zoomed(by factor: CGFloat, around anchor: CGPoint, limits: RTSPTransformLimits) -> RTSPTransform {
		guard scale > 0, factor > 0 else { return self }
		var zoomed = self
		zoomed.scale = scale * factor
		zoomed.scale = clamp(zoomed.scale, to: limits.scale)
		// Read the effective ratio back off the clamped scale: at the ends of the
		// range the scale stops moving, and the translation must stop with it.
		let ratio = zoomed.scale / scale
		zoomed.translation = CGPoint(
			x: anchor.x - ratio * (anchor.x - translation.x),
			y: anchor.y - ratio * (anchor.y - translation.y)
		)
		return zoomed.clamped(to: limits)
	}

	func rotated(by degrees: CGFloat, limits: RTSPTransformLimits) -> RTSPTransform {
		var rotated = self
		rotated.rotation += degrees
		return rotated.clamped(to: limits)
	}

	/// The translation is held to the ranges of the *clamped* zoom and angle, so a
	/// gesture that zooms in and drags at once is measured against the room it
	/// ends up with, not the room it started from.
	func clamped(to limits: RTSPTransformLimits) -> RTSPTransform {
		let scale = clamp(self.scale, to: limits.scale)
		let rotation = clamp(self.rotation, to: limits.rotation)
		let ranges = limits.translationRanges(scale: scale, rotation: rotation)
		return RTSPTransform(
			scale: scale,
			translation: CGPoint(
				x: clamp(translation.x, to: ranges.x),
				y: clamp(translation.y, to: ranges.y)
			),
			rotation: rotation
		)
	}
}

func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
	min(max(value, range.lowerBound), range.upperBound)
}

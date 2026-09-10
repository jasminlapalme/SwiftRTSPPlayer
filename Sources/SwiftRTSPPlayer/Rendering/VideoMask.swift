//
//  VideoMask.swift
//  SwiftRTSPPlayer
//

import CoreGraphics

/// Crops the picture to a rectangle, painting everything outside it black.
///
/// Each side is the fraction hidden from that edge, so `.identity` (all zeros)
/// shows the whole frame. `anchor` says what the rectangle is pinned to, which
/// is also where in the rendering chain it applies.
///
/// Use it to hide what a camera sees but the viewer shouldn't — a ceiling, a
/// neighbouring property, the smeared border of a wide-angle lens.
public struct VideoMask: Equatable, Sendable, Codable {

	/// Where the mask sits in the chain that runs picture → fisheye correction
	/// → framing → view.
	public enum Anchor: Sendable, Codable, CaseIterable {
		/// First: pinned to the picture the camera sends. The rectangle turns and
		/// travels with the image, and bows with a fisheye correction.
		case image
		/// Last: pinned to the view. A fixed window, which the image moves behind
		/// as it is scaled, turned or dragged.
		case view
	}

	public var left: CGFloat
	public var right: CGFloat
	public var top: CGFloat
	public var bottom: CGFloat
	public var anchor: Anchor

	public init(
		left: CGFloat = 0,
		right: CGFloat = 0,
		top: CGFloat = 0,
		bottom: CGFloat = 0,
		anchor: Anchor = .image
	) {
		self.left = left
		self.right = right
		self.top = top
		self.bottom = bottom
		self.anchor = anchor
	}

	public static let identity = VideoMask()

	/// True when nothing is hidden — the anchor of an open mask is moot.
	public var isIdentity: Bool { left == 0 && right == 0 && top == 0 && bottom == 0 }

	/// The kept portion, in unit coordinates with a top-left origin. Empty once
	/// the two sides of an axis overlap — an all-black frame.
	public var visibleRect: CGRect {
		let width = 1 - left - right
		let height = 1 - top - bottom
		guard width > 0, height > 0 else { return .zero }
		return CGRect(x: left, y: top, width: width, height: height)
	}

	/// `visibleRect` laid onto a rectangle of real coordinates — the destination
	/// a view-anchored mask cuts down.
	public func visibleRect(in rect: CGRect) -> CGRect {
		let unit = visibleRect
		guard !unit.isEmpty else { return .zero }
		return CGRect(
			x: rect.minX + unit.minX * rect.width,
			y: rect.minY + unit.minY * rect.height,
			width: unit.width * rect.width,
			height: unit.height * rect.height
		)
	}
}

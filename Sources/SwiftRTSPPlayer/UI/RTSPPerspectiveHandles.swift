//
//  RTSPPerspectiveHandles.swift
//  SwiftRTSPPlayer
//

import SwiftUI

/// Where the corrected picture sits in a view while its perspective is edited: fitted, centred, unframed.
struct PerspectiveHandleLayout: Equatable {
	var videoSize: CGSize
	var viewSize: CGSize

	var pictureRect: CGRect {
		guard videoSize.width > 0, videoSize.height > 0 else { return .zero }
		let fitScale = min(viewSize.width / videoSize.width, viewSize.height / videoSize.height)
		let size = CGSize(width: videoSize.width * fitScale, height: videoSize.height * fitScale)
		return CGRect(
			x: (viewSize.width - size.width) / 2,
			y: (viewSize.height - size.height) / 2,
			width: size.width,
			height: size.height
		)
	}

	/// A corner, in unit coordinates of the picture, as a point of the view.
	func point(for corner: CGPoint) -> CGPoint {
		let rect = pictureRect
		return CGPoint(x: rect.minX + corner.x * rect.width, y: rect.minY + corner.y * rect.height)
	}

	/// The reverse of `point(for:)`, kept within `VideoPerspective.editableRange`.
	func corner(at point: CGPoint) -> CGPoint {
		let rect = pictureRect
		guard rect.width > 0, rect.height > 0 else { return .zero }
		let range = VideoPerspective.editableRange
		return CGPoint(
			x: min(max((point.x - rect.minX) / rect.width, range.lowerBound), range.upperBound),
			y: min(max((point.y - rect.minY) / rect.height, range.lowerBound), range.upperBound)
		)
	}
}

#if !os(tvOS)

/// Four handles to drag onto the corners of a rectangle the camera sees at an angle.
struct RTSPPerspectiveHandles: View {
	@Binding var perspective: VideoPerspective
	let videoSize: CGSize

	/// Where each dragged handle stood when its drag began, so it moves by the drag rather than jumping under the finger.
	@State private var dragOrigins: [VideoPerspective.Corner: CGPoint] = [:]

	private static let handleSize: CGFloat = 22
	private static let hitSize: CGFloat = 44

	var body: some View {
		GeometryReader { proxy in
			let layout = PerspectiveHandleLayout(videoSize: videoSize, viewSize: proxy.size)
			let points = VideoPerspective.Corner.allCases.map { layout.point(for: perspective[$0]) }
			ZStack {
				Path { path in
					path.addLines(points)
					path.closeSubpath()
				}
				.stroke(Color.yellow, lineWidth: 2)
				.shadow(color: .black.opacity(0.6), radius: 1.5)
				.allowsHitTesting(false)

				ForEach(VideoPerspective.Corner.allCases, id: \.self) { corner in
					handle
						.position(layout.point(for: perspective[corner]))
						.gesture(drag(corner, layout: layout))
				}
			}
		}
		.clipped()
	}

	private var handle: some View {
		Circle()
			.fill(Color.yellow.opacity(0.35))
			.overlay(Circle().strokeBorder(Color.yellow, lineWidth: 2))
			.frame(width: Self.handleSize, height: Self.handleSize)
			.shadow(color: .black.opacity(0.6), radius: 1.5)
			.frame(width: Self.hitSize, height: Self.hitSize)
			.contentShape(Circle())
	}

	private func drag(_ corner: VideoPerspective.Corner, layout: PerspectiveHandleLayout) -> some Gesture {
		DragGesture(minimumDistance: 0)
			.onChanged { value in
				let origin = dragOrigins[corner] ?? layout.point(for: perspective[corner])
				dragOrigins[corner] = origin
				perspective[corner] = layout.corner(at: CGPoint(
					x: origin.x + value.translation.width,
					y: origin.y + value.translation.height
				))
			}
			.onEnded { _ in
				dragOrigins[corner] = nil
			}
	}
}

#endif

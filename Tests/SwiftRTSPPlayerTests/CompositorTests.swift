import CoreGraphics
import Testing
import simd
@testable import SwiftRTSPPlayer

// MARK: - RTSPCompositionLayer.placementMatrix

/// Checks where the picture's corners land rather than the matrix itself: a
/// wrong sign shows up as a corner on the wrong side.
@Suite("RTSPCompositor placement")
struct CompositorTransformTests {

	/// Where the quad corner `(x, y)` ends up, in clip space.
	private func corner(
		_ point: SIMD2<Float>,
		layer: RTSPCompositionLayer,
		source: CGSize,
		destination: CGSize
	) -> SIMD2<Float> {
		let matrix = layer.placementMatrix(source: source, destination: destination)
		let result = matrix * SIMD4<Float>(point.x, point.y, 0, 1)
		return SIMD2<Float>(result.x, result.y)
	}

	private func layer(
		scale: CGFloat = 1,
		translation: CGPoint = .zero,
		rotation: CGFloat = 0
	) -> RTSPCompositionLayer {
		RTSPCompositionLayer(
			pixelBuffer: nil, frame: .zero,
			scale: scale, translation: translation, rotation: rotation
		)
	}

	private let tolerance: Float = 0.0001

	@Test("A matching aspect ratio fills the destination exactly")
	func fillsDestination() {
		let topRight = corner(
			SIMD2(1, 1), layer: layer(),
			source: CGSize(width: 1920, height: 1080),
			destination: CGSize(width: 960, height: 540)
		)
		#expect(abs(topRight.x - 1) < tolerance)
		#expect(abs(topRight.y - 1) < tolerance)
	}

	@Test("A wider picture is letterboxed, not stretched")
	func letterboxesWiderSource() {
		// 16:9 inside a square: full width, 9/16 of the height.
		let topRight = corner(
			SIMD2(1, 1), layer: layer(),
			source: CGSize(width: 1920, height: 1080),
			destination: CGSize(width: 1000, height: 1000)
		)
		#expect(abs(topRight.x - 1) < tolerance)
		#expect(abs(topRight.y - Float(9.0 / 16.0)) < tolerance)
	}

	@Test("Scale zooms about the centre")
	func scaleZooms() {
		let topRight = corner(
			SIMD2(1, 1), layer: layer(scale: 2),
			source: CGSize(width: 1920, height: 1080),
			destination: CGSize(width: 960, height: 540)
		)
		#expect(abs(topRight.x - 2) < tolerance)
		#expect(abs(topRight.y - 2) < tolerance)
	}

	@Test("Translation is a fraction of the destination, y pointing down")
	func translationIsFractional() {
		// A quarter of the width to the right and a tenth of the height down.
		let centre = corner(
			SIMD2(0, 0), layer: layer(translation: CGPoint(x: 0.25, y: 0.1)),
			source: CGSize(width: 1920, height: 1080),
			destination: CGSize(width: 960, height: 540)
		)
		// Clip space spans -1...1, so a quarter of the width is 0.5.
		#expect(abs(centre.x - 0.5) < tolerance)
		// Down on screen is negative in clip space.
		#expect(abs(centre.y - -0.2) < tolerance)
	}

	@Test("A quarter turn sends the top-right corner to the bottom right")
	func rotationTurnsClockwise() {
		// A square picture in a square destination keeps the arithmetic simple:
		// 90° clockwise moves (1, 1) — top right on screen — to bottom right.
		let corner90 = corner(
			SIMD2(1, 1), layer: layer(rotation: 90),
			source: CGSize(width: 1000, height: 1000),
			destination: CGSize(width: 800, height: 800)
		)
		#expect(abs(corner90.x - 1) < tolerance)
		#expect(abs(corner90.y - -1) < tolerance)
	}

	@Test("Rotation stays circular when the destination is not square")
	func rotationIsCircularInPixels() {
		// A square picture in a 2:1 destination fits to the height. Turned 90°
		// it must still be square in pixels.
		let source = CGSize(width: 1000, height: 1000)
		let destination = CGSize(width: 1600, height: 800)
		let turned = corner(
			SIMD2(1, 1), layer: layer(rotation: 90),
			source: source, destination: destination
		)
		// 400 pt across on an 800 pt half-width → 0.5 in clip space.
		#expect(abs(turned.x - 0.5) < tolerance)
		#expect(abs(turned.y - -1) < tolerance)
	}

	@Test("A degenerate size falls back to the identity")
	func degenerateSizes() {
		let matrix = layer().placementMatrix(
			source: .zero, destination: CGSize(width: 100, height: 100)
		)
		#expect(matrix == matrix_identity_float4x4)
	}
}

import CoreMedia
import CoreVideo
import Metal
import Testing
@testable import SwiftRTSPPlayer

// MARK: - Rendering on the GPU

/// Exercises the real Metal path: a renderer that cannot reach the shaders at
/// runtime fails to initialise, and every test here catches it.
@Suite("RTSPCompositor rendering")
struct CompositorRenderTests {

	/// An NV12 picture of a single flat colour, the shape the decoder produces.
	private func makePicture(
		width: Int, height: Int, luma: UInt8, chroma: UInt8
	) -> CVPixelBuffer? {
		let attributes: [String: Any] = [
			kCVPixelBufferMetalCompatibilityKey as String: true,
			kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
		]
		var buffer: CVPixelBuffer?
		guard CVPixelBufferCreate(
			nil, width, height,
			kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
			attributes as CFDictionary, &buffer
		) == kCVReturnSuccess, let buffer else { return nil }

		CVPixelBufferLockBaseAddress(buffer, [])
		defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
		for (plane, value) in [(0, luma), (1, chroma)] {
			guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return nil }
			let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
			let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
			memset(base, Int32(value), bytesPerRow * rows)
		}
		return buffer
	}

	private struct Colour: Equatable {
		var red: Int
		var green: Int
		var blue: Int
	}

	/// The colour at a point of a composed frame, given as fractions of its
	/// size, read from its BGRA bytes.
	private func colour(
		of frame: RTSPComposedFrame, atX xFraction: Double = 0.5, y yFraction: Double = 0.5
	) -> Colour? {
		let buffer = frame.pixelBuffer
		CVPixelBufferLockBaseAddress(buffer, .readOnly)
		defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
		guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

		let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
		let row = Int(Double(CVPixelBufferGetHeight(buffer)) * yFraction)
		let column = Int(Double(CVPixelBufferGetWidth(buffer)) * xFraction)
		let pixel = base.advanced(by: row * bytesPerRow + column * 4)
			.assumingMemoryBound(to: UInt8.self)
		return Colour(red: Int(pixel[2]), green: Int(pixel[1]), blue: Int(pixel[0]))
	}

	private func centreColour(of frame: RTSPComposedFrame) -> Colour? {
		colour(of: frame)
	}

	@Test("A compositor can be created — the shaders are reachable at runtime")
	func compositorInitialises() async throws {
		// No GPU on this machine (a bare CI container): nothing to assert.
		try #require(MTLCreateSystemDefaultDevice() != nil)
		#expect(RTSPCompositor(width: 64, height: 64) != nil)
	}

	@Test("A white picture composes to white pixels")
	func drawsThePicture() async throws {
		try #require(MTLCreateSystemDefaultDevice() != nil)
		let compositor = try #require(RTSPCompositor(width: 32, height: 32))
		// Limited-range white with neutral chroma.
		let picture = try #require(makePicture(width: 64, height: 64, luma: 235, chroma: 128))

		let layer = RTSPCompositionLayer(
			pixelBuffer: picture,
			frame: CGRect(x: 0, y: 0, width: 32, height: 32)
		)
		let frame = try #require(await compositor.render(layers: [layer], time: .zero))
		let colour = try #require(centreColour(of: frame))

		#expect(colour.red > 250)
		#expect(colour.green > 250)
		#expect(colour.blue > 250)
	}

	@Test("A layer with no picture leaves its place black")
	func missingPictureStaysBlack() async throws {
		try #require(MTLCreateSystemDefaultDevice() != nil)
		let compositor = try #require(RTSPCompositor(width: 32, height: 32))

		let layer = RTSPCompositionLayer(
			pixelBuffer: nil,
			frame: CGRect(x: 0, y: 0, width: 32, height: 32)
		)
		let frame = try #require(await compositor.render(layers: [layer], time: .zero))
		let colour = try #require(centreColour(of: frame))

		#expect(colour == Colour(red: 0, green: 0, blue: 0))
	}

	@Test("A mask blacks out the edges it hides and keeps the rest")
	func maskHidesTheEdges() async throws {
		try #require(MTLCreateSystemDefaultDevice() != nil)
		let compositor = try #require(RTSPCompositor(width: 32, height: 32))
		let picture = try #require(makePicture(width: 32, height: 32, luma: 235, chroma: 128))

		let layer = RTSPCompositionLayer(
			pixelBuffer: picture,
			frame: CGRect(x: 0, y: 0, width: 32, height: 32),
			mask: VideoMask(left: 0.25, top: 0.25)
		)
		let frame = try #require(await compositor.render(layers: [layer], time: .zero))

		let hidden = try #require(colour(of: frame, atX: 0.1, y: 0.1))
		#expect(hidden == Colour(red: 0, green: 0, blue: 0))
		let kept = try #require(centreColour(of: frame))
		#expect(kept.red > 250)
	}

	@Test("An image-anchored mask travels: rotated, it hides the other edge")
	func maskFollowsTheRotation() async throws {
		try #require(MTLCreateSystemDefaultDevice() != nil)
		let compositor = try #require(RTSPCompositor(width: 32, height: 32))
		let picture = try #require(makePicture(width: 32, height: 32, luma: 235, chroma: 128))

		// Turned a half-turn, the mask on the top edge lands on the bottom one.
		let layer = RTSPCompositionLayer(
			pixelBuffer: picture,
			frame: CGRect(x: 0, y: 0, width: 32, height: 32),
			rotation: 180,
			mask: VideoMask(top: 0.25)
		)
		let frame = try #require(await compositor.render(layers: [layer], time: .zero))

		let top = try #require(colour(of: frame, atX: 0.5, y: 0.1))
		#expect(top.red > 250)
		let bottom = try #require(colour(of: frame, atX: 0.5, y: 0.9))
		#expect(bottom == Colour(red: 0, green: 0, blue: 0))
	}

	@Test("A view-anchored mask stays put: rotated, it still hides the top")
	func viewAnchoredMaskIgnoresTheRotation() async throws {
		try #require(MTLCreateSystemDefaultDevice() != nil)
		let compositor = try #require(RTSPCompositor(width: 32, height: 32))
		let picture = try #require(makePicture(width: 32, height: 32, luma: 235, chroma: 128))

		// The same half-turn as above, which an image-anchored mask followed.
		let layer = RTSPCompositionLayer(
			pixelBuffer: picture,
			frame: CGRect(x: 0, y: 0, width: 32, height: 32),
			rotation: 180,
			mask: VideoMask(top: 0.25, anchor: .view)
		)
		let frame = try #require(await compositor.render(layers: [layer], time: .zero))

		let top = try #require(colour(of: frame, atX: 0.5, y: 0.1))
		#expect(top == Colour(red: 0, green: 0, blue: 0))
		let bottom = try #require(colour(of: frame, atX: 0.5, y: 0.9))
		#expect(bottom.red > 250)
	}

	@Test("A view-anchored mask cuts the view, not the picture behind it")
	func viewAnchoredMaskDoesNotMoveWithTheImage() async throws {
		try #require(MTLCreateSystemDefaultDevice() != nil)
		let compositor = try #require(RTSPCompositor(width: 32, height: 32))
		let picture = try #require(makePicture(width: 32, height: 32, luma: 235, chroma: 128))

		// Dragged down by a third of the tile, the window it shows through stays.
		let layer = RTSPCompositionLayer(
			pixelBuffer: picture,
			frame: CGRect(x: 0, y: 0, width: 32, height: 32),
			translation: CGPoint(x: 0, y: 0.33),
			mask: VideoMask(top: 0.25, anchor: .view)
		)
		let frame = try #require(await compositor.render(layers: [layer], time: .zero))

		let top = try #require(colour(of: frame, atX: 0.5, y: 0.1))
		#expect(top == Colour(red: 0, green: 0, blue: 0))
		let centre = try #require(centreColour(of: frame))
		#expect(centre.red > 250)
	}

	@Test("Odd dimensions are rounded up — encoders reject them")
	func roundsToEvenDimensions() async throws {
		try #require(MTLCreateSystemDefaultDevice() != nil)
		let compositor = try #require(RTSPCompositor(width: 31, height: 17))
		#expect(compositor.width == 32)
		#expect(compositor.height == 18)
	}
}

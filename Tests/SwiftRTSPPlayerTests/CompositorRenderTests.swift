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

	/// The colour at the centre of a composed frame, read from its BGRA bytes.
	private func centreColour(of frame: RTSPComposedFrame) -> Colour? {
		let buffer = frame.pixelBuffer
		CVPixelBufferLockBaseAddress(buffer, .readOnly)
		defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
		guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

		let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
		let row = CVPixelBufferGetHeight(buffer) / 2
		let column = CVPixelBufferGetWidth(buffer) / 2
		let pixel = base.advanced(by: row * bytesPerRow + column * 4)
			.assumingMemoryBound(to: UInt8.self)
		return Colour(red: Int(pixel[2]), green: Int(pixel[1]), blue: Int(pixel[0]))
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

	@Test("Odd dimensions are rounded up — encoders reject them")
	func roundsToEvenDimensions() async throws {
		try #require(MTLCreateSystemDefaultDevice() != nil)
		let compositor = try #require(RTSPCompositor(width: 31, height: 17))
		#expect(compositor.width == 32)
		#expect(compositor.height == 18)
	}
}

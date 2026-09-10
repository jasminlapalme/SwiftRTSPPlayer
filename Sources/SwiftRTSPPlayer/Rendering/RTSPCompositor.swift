//
//  RTSPCompositor.swift
//  SwiftRTSPPlayer
//

import CoreMedia
import CoreVideo
import Metal
import simd

/// One video placed in a composition. `scale` 1 fits the picture inside
/// `frame`, `translation` is a fraction of that frame, `rotation` is degrees.
public struct RTSPCompositionLayer: @unchecked Sendable {

	/// `nil` leaves the destination black, so a camera still connecting keeps
	/// its place.
	public var pixelBuffer: CVPixelBuffer?
	/// Destination inside the composition, in output pixels, top-left origin.
	public var frame: CGRect
	public var scale: CGFloat
	public var translation: CGPoint
	public var rotation: CGFloat
	public var fisheyeCorrection: FisheyeCorrection
	/// Crops the picture; what it hides is drawn black, like the bare areas.
	public var mask: VideoMask

	public init(
		pixelBuffer: CVPixelBuffer?,
		frame: CGRect,
		scale: CGFloat = 1.0,
		translation: CGPoint = .zero,
		rotation: CGFloat = 0,
		fisheyeCorrection: FisheyeCorrection = .identity,
		mask: VideoMask = .identity
	) {
		self.pixelBuffer = pixelBuffer
		self.frame = frame
		self.scale = scale
		self.translation = translation
		self.rotation = rotation
		self.fisheyeCorrection = fisheyeCorrection
		self.mask = mask
	}

	/// Fits, scales, rotates about the centre, then offsets. Computed with y
	/// pointing down — the convention the framings were authored in.
	func placementMatrix(source: CGSize, destination: CGSize) -> float4x4 {
		guard source.width > 0, source.height > 0,
			destination.width > 0, destination.height > 0
		else { return matrix_identity_float4x4 }

		let fitScale = min(destination.width / source.width, destination.height / source.height)
		let drawn = CGSize(
			width: source.width * fitScale * scale,
			height: source.height * fitScale * scale
		)

		let angle = rotation * .pi / 180
		let cosA = cos(angle), sinA = sin(angle)

		// Half-extents as a fraction of the destination's: the unit quad's ±1
		// already spans one.
		let halfX = drawn.width / destination.width
		let halfY = drawn.height / destination.height
		// Keeps the rotation circular in pixels on a non-square destination.
		let aspect = destination.width / destination.height

		let column0 = SIMD4<Float>(
			Float(halfX * cosA),
			Float(-halfX * sinA * aspect),
			0, 0
		)
		let column1 = SIMD4<Float>(
			Float(halfY * sinA / aspect),
			Float(halfY * cosA),
			0, 0
		)
		let column3 = SIMD4<Float>(
			Float(2 * translation.x),
			Float(-2 * translation.y),
			0, 1
		)
		return float4x4(column0, column1, SIMD4<Float>(0, 0, 1, 0), column3)
	}
}

/// A rendered composition, ready to hand to an encoder.
public struct RTSPComposedFrame: @unchecked Sendable {
	public let pixelBuffer: CVPixelBuffer
	public let time: CMTime
}

/// Draws several streams into one offscreen `CVPixelBuffer`, ready to encode.
/// The output is BGRA, which VideoToolbox and the usual RTMP stacks accept.
public actor RTSPCompositor {

	// Fixed for the compositor's lifetime, so readable without awaiting it.
	public nonisolated let width: Int
	public nonisolated let height: Int

	private let renderer: MetalVideoRenderer
	private let pixelBufferPool: CVPixelBufferPool

	/// Dimensions are rounded up to even numbers, which H.264 encoders
	/// require.
	public init?(width: Int, height: Int) {
		let width = width + width % 2
		let height = height + height % 2
		guard width > 0, height > 0, let renderer = MetalVideoRenderer() else { return nil }

		self.width = width
		self.height = height
		self.renderer = renderer

		// A pool, not a buffer per frame: at 30 fps the allocation and IOSurface
		// setup would dominate.
		let attributes: [String: Any] = [
			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
			kCVPixelBufferWidthKey as String: width,
			kCVPixelBufferHeightKey as String: height,
			kCVPixelBufferMetalCompatibilityKey as String: true,
			kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
		]
		var pool: CVPixelBufferPool?
		guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
			let pool
		else { return nil }
		self.pixelBufferPool = pool
	}

	/// Renders `layers`, last one on top. `nil` only when GPU resources are
	/// unavailable.
	public func render(layers: [RTSPCompositionLayer], time: CMTime) async -> RTSPComposedFrame? {
		var pixelBuffer: CVPixelBuffer?
		guard CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer) == kCVReturnSuccess,
			let pixelBuffer,
			let target = renderer.makeRenderTarget(for: pixelBuffer),
			let commandBuffer = renderer.makeCommandBuffer()
		else { return nil }

		renderer.draw(layers, into: target, with: commandBuffer)
		// The buffer goes straight to an encoder, so the pixels must be final —
		// awaited rather than waited on, which would hold a cooperative thread.
		await withCheckedContinuation { continuation in
			commandBuffer.addCompletedHandler { _ in continuation.resume() }
			commandBuffer.commit()
		}
		renderer.flushTextureCache()

		return RTSPComposedFrame(pixelBuffer: pixelBuffer, time: time)
	}
}

//
//  MetalVideoRenderer.swift
//  LecteurRTSP
//
//  Created by Jasmin Lapalme on 2026-03-30.
//

import CoreVideo
import Metal
import QuartzCore
import simd

/// Applies a framing — fit, scale, translation, rotation, fisheye — into any
/// texture, so the screen and a broadcast are drawn by the same code.
final class MetalVideoRenderer {

	private struct FisheyeUniforms {
		var k1v: Float
		var k2v: Float
		var k3v: Float
		var k4v: Float
		var aspect: Float
	}

	/// Made once and shared: building a library costs milliseconds we would
	/// otherwise pay per camera.
	private static let shared: (device: MTLDevice, library: MTLLibrary)? = {
		guard let device = MTLCreateSystemDefaultDevice(),
			let library = makeLibrary(device: device)
		else { return nil }
		return (device, library)
	}()

	/// Xcode compiles the shaders into the bundle; SwiftPM has no Metal rule,
	/// so fall back to the source the package ships.
	private static func makeLibrary(device: MTLDevice) -> MTLLibrary? {
		if let compiled = try? device.makeDefaultLibrary(bundle: .module) {
			return compiled
		}
		guard let url = Bundle.module.url(forResource: "VideoShaders", withExtension: "metal"),
			let source = try? String(contentsOf: url, encoding: .utf8)
		else { return nil }
		return try? device.makeLibrary(source: source, options: nil)
	}

	let device: MTLDevice
	let commandQueue: MTLCommandQueue
	private let pipelineState: MTLRenderPipelineState
	private let textureCache: CVMetalTextureCache

	init?() {
		guard
			let shared = Self.shared,
			let queue = shared.device.makeCommandQueue()
		else { return nil }

		let device = shared.device
		self.device = device
		self.commandQueue = queue

		guard
			let vert = shared.library.makeFunction(name: "vertex_transformed"),
			let frag = shared.library.makeFunction(name: "fragment_yuv")
		else { return nil }

		let desc = MTLRenderPipelineDescriptor()
		desc.vertexFunction = vert
		desc.fragmentFunction = frag
		desc.colorAttachments[0].pixelFormat = .bgra8Unorm

		guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
		self.pipelineState = pipeline

		// Zero-copy bridge from CVPixelBuffer to MTLTexture. Without it every
		// draw fails silently, so surface the failure instead.
		var cache: CVMetalTextureCache?
		let cacheStatus = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
		guard cacheStatus == kCVReturnSuccess, let cache else { return nil }
		self.textureCache = cache
	}

	/// Wraps a whole pixel buffer as a texture to draw *into* — zero copy.
	func makeRenderTarget(for pixelBuffer: CVPixelBuffer) -> MTLTexture? {
		textureCache.makeTexture(from: pixelBuffer, pixelFormat: .bgra8Unorm, planeIndex: 0)
	}

	func makeCommandBuffer() -> MTLCommandBuffer? {
		commandQueue.makeCommandBuffer()
	}

	/// Releases the cache's textures; call once their command buffer is
	/// committed.
	func flushTextureCache() {
		CVMetalTextureCacheFlush(textureCache, 0)
	}

	/// Encodes `layers` into `target`, last one on top. Bare areas stay black,
	/// the letterboxing of the display.
	func draw(
		_ layers: [RTSPCompositionLayer],
		into target: MTLTexture,
		with commandBuffer: MTLCommandBuffer
	) {
		let passDesc = MTLRenderPassDescriptor()
		passDesc.colorAttachments[0].texture = target
		passDesc.colorAttachments[0].loadAction = .clear
		passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
		passDesc.colorAttachments[0].storeAction = .store

		guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
		encoder.setRenderPipelineState(pipelineState)

		for layer in layers {
			draw(layer, with: encoder)
		}

		encoder.endEncoding()
	}

	private func draw(_ layer: RTSPCompositionLayer, with encoder: MTLRenderCommandEncoder) {
		let destination = layer.frame.integral
		guard destination.width >= 1, destination.height >= 1,
			let pixelBuffer = layer.pixelBuffer,
			// Zero-copy: wrap the NV12 planes as textures to sample from.
			let yTex = textureCache.makeTexture(from: pixelBuffer, pixelFormat: .r8Unorm, planeIndex: 0),
			let uvTex = textureCache.makeTexture(from: pixelBuffer, pixelFormat: .rg8Unorm, planeIndex: 1)
		else { return }

		// Viewport and scissor crop a picture zoomed past its tile, the way the
		// player's layer is clipped to its view.
		encoder.setViewport(MTLViewport(
			originX: Double(destination.minX), originY: Double(destination.minY),
			width: Double(destination.width), height: Double(destination.height),
			znear: 0, zfar: 1
		))
		encoder.setScissorRect(MTLScissorRect(
			x: Int(destination.minX), y: Int(destination.minY),
			width: Int(destination.width), height: Int(destination.height)
		))

		let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
		let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
		var transform = layer.placementMatrix(
			source: CGSize(width: sourceWidth, height: sourceHeight),
			destination: destination.size
		)
		encoder.setVertexBytes(&transform, length: MemoryLayout<float4x4>.size, index: 0)

		encoder.setFragmentTexture(yTex, index: 0)
		encoder.setFragmentTexture(uvTex, index: 1)
		var fisheye = FisheyeUniforms(
			k1v: Float(layer.fisheyeCorrection.k1v),
			k2v: Float(layer.fisheyeCorrection.k2v),
			k3v: Float(layer.fisheyeCorrection.k3v),
			k4v: Float(layer.fisheyeCorrection.k4v),
			aspect: sourceHeight > 0 ? Float(sourceWidth) / Float(sourceHeight) : 1
		)
		encoder.setFragmentBytes(&fisheye, length: MemoryLayout<FisheyeUniforms>.size, index: 0)

		encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
	}
}

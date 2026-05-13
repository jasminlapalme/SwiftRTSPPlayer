//
//  MetalVideoRenderer.swift
//  LecteurRTSP
//
//  Created by Jasmin Lapalme on 2026-03-30.
//

import Metal
import QuartzCore
import CoreVideo

final class MetalVideoRenderer {
	private struct FisheyeUniforms {
		var k1v: Float
		var k2v: Float
		var k3v: Float
		var k4v: Float
		var aspect: Float
	}

	private let device: MTLDevice
	private let commandQueue: MTLCommandQueue
	private let pipelineState: MTLRenderPipelineState
	private var textureCache: CVMetalTextureCache?
	let layer: CAMetalLayer

	var fisheyeCorrection: FisheyeCorrection = .identity

	init?(layer: CAMetalLayer) {
		guard
			let device = MTLCreateSystemDefaultDevice(),
			let queue  = device.makeCommandQueue()
		else { return nil }

		self.device = device
		self.commandQueue = queue
		self.layer = layer

		layer.device = device
		layer.pixelFormat = .bgra8Unorm
		layer.framebufferOnly = true
#if os(macOS)
		layer.displaySyncEnabled = true  // vsync on tvOS
#endif
		let currentBundle = Bundle.module
		guard
			let lib  = try? device.makeDefaultLibrary(bundle: currentBundle),
			let vert = lib.makeFunction(name: "vertex_passthrough"),
			let frag = lib.makeFunction(name: "fragment_yuv")
		else { return nil }

		let desc = MTLRenderPipelineDescriptor()
		desc.vertexFunction   = vert
		desc.fragmentFunction = frag
		desc.colorAttachments[0].pixelFormat = .bgra8Unorm

		guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc)
		else { return nil }
		self.pipelineState = pipeline

		// CVMetalTextureCache: zero-copy bridge between CVPixelBuffer and MTLTexture
		var cache: CVMetalTextureCache?
		let cacheStatus = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
		guard cacheStatus == kCVReturnSuccess, let cache else {
			// Without the texture cache, render() would fail silently on every
			// frame and the user would see a permanent black screen. Surface
			// the failure to the caller so it can fall back or report it.
			return nil
		}
		self.textureCache = cache
	}

	/// Called from VideoToolbox callback with a decoded NV12 CVPixelBuffer
	func render(pixelBuffer: CVPixelBuffer) {
		guard
			let cache    = textureCache,
			let drawable = layer.nextDrawable(),
			let cmdBuf   = commandQueue.makeCommandBuffer()
		else { return }

		// Zero-copy: wrap CVPixelBuffer planes as MTLTextures
		guard
			let yTex  = cache.makeTexture(from: pixelBuffer, pixelFormat: .r8Unorm, planeIndex: 0),
			let uvTex = cache.makeTexture(from: pixelBuffer, pixelFormat: .rg8Unorm, planeIndex: 1)
		else { return }

		let passDesc = MTLRenderPassDescriptor()
		passDesc.colorAttachments[0].texture     = drawable.texture
		passDesc.colorAttachments[0].loadAction = .clear
		passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
		passDesc.colorAttachments[0].storeAction = .store

		guard let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc) else { return }
		enc.setRenderPipelineState(pipelineState)
		enc.setFragmentTexture(yTex, index: 0)
		enc.setFragmentTexture(uvTex, index: 1)
		let width = CVPixelBufferGetWidth(pixelBuffer)
		let height = CVPixelBufferGetHeight(pixelBuffer)
		var fisheye = FisheyeUniforms(
			k1v: Float(fisheyeCorrection.k1v),
			k2v: Float(fisheyeCorrection.k2v),
			k3v: Float(fisheyeCorrection.k3v),
			k4v: Float(fisheyeCorrection.k4v),
			aspect: height > 0 ? Float(width) / Float(height) : 1
		)
		enc.setFragmentBytes(&fisheye, length: MemoryLayout<FisheyeUniforms>.size, index: 0)
		enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
		enc.endEncoding()

		cmdBuf.present(drawable)
		cmdBuf.commit()

		// Flush texture cache after commit
		CVMetalTextureCacheFlush(cache, 0)
	}
}

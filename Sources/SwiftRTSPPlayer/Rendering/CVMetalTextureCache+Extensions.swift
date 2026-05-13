//
//  CVMetalTextureCache+Extensions.swift
//  LecteurRTSP
//
//  Created by Jasmin Lapalme on 2026-03-30.
//

import Metal
import CoreVideo

extension CVMetalTextureCache {
	/// Creates a MTLTexture from a plane of a CVPixelBuffer — zero copy.
	func makeTexture(
		from pixelBuffer: CVPixelBuffer,
		pixelFormat: MTLPixelFormat,
		planeIndex: Int
	) -> MTLTexture? {
		let width  = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
		let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)

		var cvTexture: CVMetalTexture?
		let status = CVMetalTextureCacheCreateTextureFromImage(
			nil, self, pixelBuffer, nil,
			pixelFormat, width, height, planeIndex,
			&cvTexture
		)
		guard status == kCVReturnSuccess, let cvTex = cvTexture else { return nil }
		return CVMetalTextureGetTexture(cvTex)
	}
}

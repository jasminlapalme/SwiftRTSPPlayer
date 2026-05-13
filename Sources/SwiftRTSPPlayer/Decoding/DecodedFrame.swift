//
//  DecodedFrame.swift
//  SwiftRTSPPlayer
//

import CoreMedia
import CoreVideo

// `CVPixelBuffer` is a CoreFoundation reference type whose thread-safety depends
// on the producer (here, VideoToolbox returns a fresh buffer per frame and the
// pipeline hands ownership off to a single consumer at a time). Rather than
// declaring a retroactive `Sendable` conformance on `CVPixelBuffer` globally —
// which would lie about the type for every client of the module — we scope the
// `@unchecked` claim to this wrapper, the only value that actually crosses
// actor boundaries.
public struct DecodedFrame: @unchecked Sendable {

	public let pixelBuffer: CVPixelBuffer
	public let pts: CMTime

}

//
//  RTSPCameraSelection.swift
//  SwiftRTSPPlayer
//

import Foundation

/// A chosen camera stream: the RTSP URL to play plus a human-readable name for
/// it. For a discovered ONVIF camera the name is its configured hostname (or the
/// discovery scope name as a fallback); for a manually entered URL it is the
/// URL's host.
public struct RTSPCameraSelection: Equatable, Sendable {
	public let url: URL
	public let name: String

	public init(url: URL, name: String) {
		self.url = url
		self.name = name
	}
}

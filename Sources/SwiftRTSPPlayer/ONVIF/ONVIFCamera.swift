//
//  ONVIFCamera.swift
//  SwiftRTSPPlayer
//

import Foundation

/// A camera discovered on the local network via ONVIF WS-Discovery.
public struct ONVIFCamera: Identifiable, Hashable, Sendable {
	/// Human-readable name from the `onvif://www.onvif.org/name/…` scope,
	/// falling back to the hardware model when the camera publishes no name.
	public let name: String
	/// Model identifier from the `onvif://www.onvif.org/hardware/…` scope.
	public let model: String
	/// IP address the probe response came from.
	public let ipAddress: String
	/// ONVIF device service endpoint (first entry of `XAddrs`). All SOAP
	/// requests for this camera are posted to this URL.
	public let deviceService: URL

	public var id: String { ipAddress }
}

/// A media profile exposed by an ONVIF camera. Each profile maps to one
/// stream configuration (e.g. main stream vs. sub stream).
public struct ONVIFProfile: Identifiable, Hashable, Sendable {
	/// Token used to reference the profile in `GetStreamUri` requests.
	public let token: String
	/// Display name of the profile.
	public let name: String

	public var id: String { token }
}

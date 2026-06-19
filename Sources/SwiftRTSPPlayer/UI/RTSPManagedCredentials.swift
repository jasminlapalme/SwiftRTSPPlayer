//
//  RTSPManagedCredentials.swift
//  SwiftRTSPPlayer
//

import Foundation

/// A named credential set the host app supplies to the cameras tab — e.g. read
/// from a keychain, a backend, or app configuration. The user picks one of these
/// (or switches to typing credentials manually) in `RTSPTransformControlPanel`'s
/// Cameras tab; the chosen set authenticates discovered ONVIF cameras and is
/// injected into a manually entered RTSP URL that carries no credentials of its
/// own.
///
/// `name` is the identity: it is shown in the picker and must be unique within
/// the array passed to the panel so the selection stays stable across redraws.
public struct RTSPManagedCredentials: Identifiable, Hashable, Sendable {
	public let name: String
	public let username: String
	public let password: String

	public var id: String { name }

	public init(name: String, username: String, password: String) {
		self.name = name
		self.username = username
		self.password = password
	}

	/// Returns `url` with these credentials embedded in its userinfo
	/// (`rtsp://user:pass@host/…`). Any userinfo already on `url` is replaced.
	public func authenticating(_ url: URL) -> URL {
		Self.embedding(username: username, password: password, in: url)
	}

	/// Embed `username`/`password` into `url`'s userinfo, replacing any present.
	/// The shared primitive behind `authenticating(_:)` and
	/// `RTSPCameraSelection.authenticatedURL(managedCredentials:)`.
	static func embedding(username: String, password: String, in url: URL) -> URL {
		guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
		components.user = username
		components.password = password
		return components.url ?? url
	}
}

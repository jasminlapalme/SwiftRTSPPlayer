//
//  RTSPCameraSelection.swift
//  SwiftRTSPPlayer
//

import Foundation

/// A chosen camera stream: the RTSP URL to play plus a human-readable name for
/// it. For a discovered ONVIF camera the name is its configured hostname (or the
/// discovery scope name as a fallback); for a manually entered URL it is the
/// URL's host.
///
/// `url` never carries credentials — `credentials` says how to authenticate it,
/// so secrets stay out of values that get persisted or logged. Call
/// `authenticatedURL(managedCredentials:)` at play time to get the URL with
/// credentials embedded.
public struct RTSPCameraSelection: Equatable, Sendable {

	/// How to authenticate `url` against the camera.
	public enum Credentials: Equatable, Sendable {
		/// The stream needs no credentials.
		case none
		/// Credentials typed by the user. They have no external store, so they
		/// travel in the selection — the only case that holds secrets directly.
		case manual(username: String, password: String)
		/// The name of a host-supplied `RTSPManagedCredentials` set. The host
		/// resolves it back to real credentials at play time, so no secret is
		/// stored here.
		case managed(name: String)
	}

	public let url: URL
	public let name: String
	public let credentials: Credentials

	public init(url: URL, name: String, credentials: Credentials = .none) {
		self.url = url
		self.name = name
		self.credentials = credentials
	}

	/// The URL to play, with credentials embedded in its userinfo. Resolves a
	/// `.managed` reference against `managedCredentials` (returning the clean URL
	/// unchanged when no set matches the name); embeds `.manual` credentials
	/// directly; and returns `url` untouched for `.none`.
	public func authenticatedURL(managedCredentials: [RTSPManagedCredentials] = []) -> URL {
		switch credentials {
		case .none:
			return url
		case let .manual(username, password):
			return RTSPManagedCredentials.embedding(username: username, password: password, in: url)
		case let .managed(name):
			guard let set = managedCredentials.first(where: { $0.name == name }) else { return url }
			return set.authenticating(url)
		}
	}
}

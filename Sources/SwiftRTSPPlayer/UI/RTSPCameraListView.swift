//
//  RTSPCameraListView.swift
//  SwiftRTSPPlayer
//

import SwiftUI

/// The cameras tab of `RTSPTransformControlPanel`, usable on its own: ONVIF
/// credential fields, the list of cameras discovered on the local network, and
/// a manual RTSP URL field. Picking a camera (or submitting a URL) writes the
/// resolved stream to `selection`.
///
/// Discovery runs while the view is visible. The typed credentials and URL live
/// in the view itself, so wrap it in a container that stays alive (or recreate
/// it per presentation, like a sheet) rather than tearing it down on every
/// state change.
///
/// ```swift
/// RTSPCameraListView(
///     selection: $cameraSelection,
///     managedCredentials: [RTSPManagedCredentials(name: "Admin", username: "admin", password: "…")]
/// )
/// ```
public struct RTSPCameraListView: View {

	private let selection: Binding<RTSPCameraSelection?>
	private let managedCredentials: [RTSPManagedCredentials]

	@State private var username: String
	@State private var password: String
	@State private var manualURL: String
	@State private var selectedCredentialID: String?

	public init(
		selection: Binding<RTSPCameraSelection?>,
		managedCredentials: [RTSPManagedCredentials] = []
	) {
		self.selection = selection
		self.managedCredentials = managedCredentials
		let seed = CameraFieldSeed(selection: selection.wrappedValue, managedCredentials: managedCredentials)
		self._username = State(initialValue: seed.username)
		self._password = State(initialValue: seed.password)
		self._manualURL = State(initialValue: seed.manualURL)
		self._selectedCredentialID = State(initialValue: seed.credentialID)
	}

	public var body: some View {
		ONVIFCameraListView(
			currentSelection: selection,
			username: $username,
			password: $password,
			manualURL: $manualURL,
			managedCredentials: managedCredentials,
			selectedCredentialID: $selectedCredentialID
		)
	}
}

/// Initial values for the cameras tab's fields, derived from the stream already
/// in play: the current URL (credential-free) and the credential source it was
/// set with. Shared by `RTSPCameraListView` and `RTSPTransformControlPanel`,
/// which both own the fields' state.
struct CameraFieldSeed {
	var username = ""
	var password = ""
	var manualURL: String
	/// The `name` of the managed set to preselect, or `nil` for the manual
	/// username/password source. Managed by default: the first set when the host
	/// supplied any, unless the stream in play was set with a different source.
	var credentialID: String?

	init(selection: RTSPCameraSelection?, managedCredentials: [RTSPManagedCredentials]) {
		manualURL = selection?.url.absoluteString ?? ""
		credentialID = managedCredentials.first?.id
		switch selection?.credentials ?? .none {
		case .none:
			break
		case let .manual(user, pass):
			username = user
			password = pass
			credentialID = nil
		case let .managed(name):
			if managedCredentials.contains(where: { $0.id == name }) {
				credentialID = name
			}
		}
	}
}

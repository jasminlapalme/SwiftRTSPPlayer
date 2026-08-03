//
//  ONVIFCameraListView.swift
//  SwiftRTSPPlayer
//

import SwiftUI

/// Content of the "Cameras" tab in `RTSPTransformControlPanel`: credentials
/// fields and the list of ONVIF cameras discovered on the local network.
/// Discovery runs continuously while the tab is visible — cameras appear as
/// they answer probes and drop off the list once they stop answering.
/// Tapping a camera resolves its RTSP stream URL (first media profile) and
/// writes it (with the camera's name) to `currentSelection`; the camera matching
/// the selection's host shows a checkmark, including when it was set before the
/// panel opened.
/// Horizontal inset used by the standalone panel; none on macOS, where the
/// hosting form draws its own row insets.
private struct PanelHorizontalPadding: ViewModifier {
	func body(content: Content) -> some View {
#if os(macOS)
		content
#else
		content.padding(.horizontal)
#endif
	}
}

struct ONVIFCameraListView: View {

	/// A camera vanishing for this long is considered gone (~2 missed probe
	/// rounds plus margin).
	private static let cameraExpiry: TimeInterval = 10

	let currentSelection: Binding<RTSPCameraSelection?>

	/// Owned by the parent panel so the typed credentials survive tab switches —
	/// this view is torn down when another tab is shown.
	@Binding var username: String
	@Binding var password: String
	/// A manually typed RTSP URL, an alternative to picking a discovered camera.
	/// Owned by the parent for the same reason as the credentials above.
	@Binding var manualURL: String
	/// Named credential sets supplied by the host app. When non-empty the user
	/// can pick one instead of typing credentials manually.
	let managedCredentials: [RTSPManagedCredentials]
	/// The chosen credential source: the `name` of a managed set, or `nil` for
	/// the manually typed username/password. Owned by the parent so it survives
	/// tab switches.
	@Binding var selectedCredentialID: String?
	@State private var discovered: [ONVIFCamera.ID: (camera: ONVIFCamera, lastSeen: Date)] = [:]
	@State private var hostnames: [ONVIFCamera.ID: String] = [:]
	@State private var hostnameRequests: Set<ONVIFCamera.ID> = []
	@State private var hasCompletedRound = false
	@State private var connectingCameraID: ONVIFCamera.ID?
	@State private var errorMessage: String?

	private var cameras: [ONVIFCamera] {
		discovered.values.map(\.camera).sorted { cam1, cam2 in
			let name1 = hostnames[cam1.id] ?? cam1.name
			let name2 = hostnames[cam2.id] ?? cam2.name
			return (name1, cam1.ipAddress) < (name2, cam2.ipAddress)
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			credentialFields
			if hasCompletedRound && cameras.isEmpty {
				Text(String(localized: "cameras.empty", bundle: .module))
					.font(.caption)
					.foregroundStyle(.secondary)
					.modifier(PanelHorizontalPadding())
			}
			if let errorMessage {
				Text(errorMessage)
					.font(.caption)
					.foregroundStyle(.red)
					.modifier(PanelHorizontalPadding())
			}
			cameraList
		}
		.padding(.vertical, 4)
		// Scan in a loop while the tab is visible. The task is cancelled on
		// disappear, which closes the UDP socket.
		.task {
			while !Task.isCancelled {
				await scanOnce()
			}
		}
		// Switching credential source re-attempts the connection for whatever is
		// already selected, so the stream picks up the new credentials at once.
		.onChange(of: selectedCredentialID) { _, _ in
			reconnectForCredentialChange()
		}
	}

	/// Whether the player's current URL points at this camera — true right
	/// after a successful selection here, but also when the client app was
	/// already configured with this camera's stream before the panel opened.
	private func isCurrent(_ camera: ONVIFCamera) -> Bool {
		currentSelection.wrappedValue?.url.host() == camera.ipAddress
	}

	// MARK: - Credentials

	/// The managed set the user picked, or `nil` when the manual source is
	/// active (no managed sets, the manual entry chosen, or a stale id).
	private var selectedManaged: RTSPManagedCredentials? {
		guard let selectedCredentialID else { return nil }
		return managedCredentials.first { $0.id == selectedCredentialID }
	}

	/// True when credentials come from the manual fields rather than a managed set.
	private var isManualSource: Bool { selectedManaged == nil }

	/// The credentials to authenticate ONVIF requests with — the picked managed
	/// set, or the manually typed pair. Used only for the SOAP calls during
	/// discovery; the stored selection carries the tagged `Credentials` instead.
	private var effectiveCredentials: ONVIFCredentials {
		if let managed = selectedManaged {
			return ONVIFCredentials(username: managed.username, password: managed.password)
		}
		return ONVIFCredentials(username: username, password: password)
	}

	/// The credential tag to attach to a selection for the active source: the
	/// picked managed set by name, the typed pair, or none when empty.
	private var selectedCredentials: RTSPCameraSelection.Credentials {
		if let managed = selectedManaged {
			return .managed(name: managed.name)
		}
		if username.isEmpty && password.isEmpty {
			return .none
		}
		return .manual(username: username, password: password)
	}

	/// Store a credential-free `url` as the current selection, tagged with how to
	/// authenticate it. Any userinfo on `url` is stripped so secrets never live
	/// in `RTSPCameraSelection`.
	private func select(url: URL, name: String, credentials: RTSPCameraSelection.Credentials) {
		currentSelection.wrappedValue = RTSPCameraSelection(
			url: Self.strippingCredentials(from: url),
			name: name,
			credentials: credentials
		)
	}

	/// Drop any userinfo from `url`, leaving the scheme, host, port and path.
	private static func strippingCredentials(from url: URL) -> URL {
		guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
		components.user = nil
		components.password = nil
		return components.url ?? url
	}

	// MARK: - Actions

	/// The trimmed manual entry as a URL, or `nil` when it isn't a usable
	/// absolute URL (empty, no scheme, or no host).
	private var parsedManualURL: URL? {
		let trimmed = manualURL.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let url = URL(string: trimmed), url.scheme != nil, url.host() != nil else { return nil }
		return url
	}

	/// Play the manually entered URL, replacing any discovered selection. The URL
	/// is stored credential-free: with a managed source the chosen set is
	/// referenced by name; otherwise credentials embedded in the typed URL are
	/// lifted into a `.manual` tag, falling back to the typed username/password.
	private func connectToManualURL() {
		guard let url = parsedManualURL else { return }
		errorMessage = nil
		let credentials: RTSPCameraSelection.Credentials
		if isManualSource, let user = url.user() {
			credentials = .manual(username: user, password: url.password() ?? "")
		} else {
			credentials = selectedCredentials
		}
		select(url: url, name: url.host() ?? url.absoluteString, credentials: credentials)
	}

	/// One probe round: collect answers until the discovery stream times out,
	/// then drop the cameras that haven't answered for a while. On failure
	/// (e.g. broadcast not permitted) back off before the loop retries.
	private func scanOnce() async {
		do {
			for try await camera in ONVIFDiscoveryService.discoverCameras() {
				discovered[camera.id] = (camera, Date())
				errorMessage = nil
				fetchHostnameIfNeeded(for: camera)
			}
			hasCompletedRound = true
			let expiryDate = Date(timeIntervalSinceNow: -Self.cameraExpiry)
			discovered = discovered.filter { $0.value.lastSeen > expiryDate }
		} catch {
			guard !Task.isCancelled else { return }
			errorMessage = error.localizedDescription
			try? await Task.sleep(for: .seconds(5))
		}
	}

	/// Ask the camera for its configured hostname, once per camera. A failed
	/// request leaves no cache entry, so the next probe round retries it.
	private func fetchHostnameIfNeeded(for camera: ONVIFCamera) {
		guard hostnames[camera.id] == nil, hostnameRequests.insert(camera.id).inserted else { return }
		Task {
			defer { hostnameRequests.remove(camera.id) }
			if let hostname = try? await ONVIFDiscoveryService.hostname(for: camera) {
				hostnames[camera.id] = hostname
			}
		}
	}

	private func connect(to camera: ONVIFCamera) {
		guard connectingCameraID == nil else { return }
		connectingCameraID = camera.id
		errorMessage = nil
		Task {
			defer { connectingCameraID = nil }
			do {
				let url = try await ONVIFDiscoveryService.streamURL(for: camera, credentials: effectiveCredentials)
				let name = hostnames[camera.id] ?? camera.name
				select(url: url, name: name, credentials: selectedCredentials)
			} catch {
				// A previously selected camera keeps playing on failure, so
				// its checkmark stays where it is.
				errorMessage = error.localizedDescription
			}
		}
	}
}

// MARK: - Subviews

private extension ONVIFCameraListView {

	@ViewBuilder
	var credentialFields: some View {
		VStack(alignment: .leading, spacing: 10) {
			if !managedCredentials.isEmpty {
				credentialSourcePicker
			}
			// Only the manual source exposes editable fields; a managed set
			// carries its own username/password.
			if isManualSource {
				manualCredentialFields
			}
		}
#if !os(macOS)
		.padding(.horizontal)
#endif
	}

	/// Lets the user pick a host-supplied credential set or fall back to typing
	/// credentials by hand. Shown only when the host supplied managed sets.
	var credentialSourcePicker: some View {
		Picker(String(localized: "cameras.credentialSource", bundle: .module), selection: $selectedCredentialID) {
			ForEach(managedCredentials) { cred in
				Text(cred.name).tag(Optional(cred.id))
			}
			Text(String(localized: "cameras.credentialSource.manual", bundle: .module)).tag(String?.none)
		}
		.pickerStyle(.menu)
	}

	private var usernameLabel: String {
		String(localized: "cameras.username", bundle: .module)
	}

	private var passwordLabel: String {
		String(localized: "cameras.password", bundle: .module)
	}

	var manualCredentialFields: some View {
#if os(macOS)
		// One row per field: side by side they become unreadable in a narrow
		// panel. A field's title is a *label*, and SwiftUI places it differently
		// depending on the host — inside the field as a placeholder when there's
		// no label column, in the leading column when there is one (a Form, an
		// inspector). Passing the title as `prompt` too keeps the field
		// self-describing either way, as `manualURLField` already does.
		VStack(spacing: 10) {
			TextField(
				usernameLabel,
				text: $username,
				prompt: Text(verbatim: usernameLabel)
			)
			.textContentType(.username)
			SecureField(
				passwordLabel,
				text: $password,
				prompt: Text(verbatim: passwordLabel)
			)
			.textContentType(.password)
		}
		// `.grouped` forms default their fields to a borderless style, which
		// leaves nothing visible to click; the other hosts already draw a border.
		.textFieldStyle(.roundedBorder)
#else
		HStack(spacing: 10) {
			TextField(usernameLabel, text: $username)
				.textContentType(.username)
			SecureField(passwordLabel, text: $password)
				.textContentType(.password)
		}
#if !os(tvOS)
		.textFieldStyle(.roundedBorder)
#endif
#if os(iOS) || os(visionOS)
		.textInputAutocapitalization(.never)
		.autocorrectionDisabled()
#endif
#endif
	}

	/// Manual RTSP URL entry, for cameras that don't answer discovery probes
	/// (different subnet, multicast blocked, non-ONVIF device). Credentials can
	/// be embedded in the URL (`rtsp://user:pass@host/path`). Submitting a valid
	/// URL connects to it immediately.
	var manualURLField: some View {
#if os(macOS)
		// In a Form the field's title becomes the row label, so give it a real
		// one and keep the example URL as the prompt.
		TextField(
			String(localized: "cameras.manualURL", bundle: .module),
			text: $manualURL,
			prompt: Text(verbatim: String(localized: "cameras.manualURL.placeholder", bundle: .module))
		)
		.textContentType(.URL)
		.textFieldStyle(.roundedBorder)
		.onSubmit(connectToManualURL)
#else
		TextField(String(localized: "cameras.manualURL.placeholder", bundle: .module), text: $manualURL)
			.textContentType(.URL)
#if os(iOS) || os(visionOS)
			.keyboardType(.URL)
#endif
			.onSubmit(connectToManualURL)
#if !os(tvOS)
			.textFieldStyle(.roundedBorder)
#endif
#if os(iOS) || os(visionOS)
			.textInputAutocapitalization(.never)
			.autocorrectionDisabled()
#endif
#endif
	}

	var cameraList: some View {
#if os(macOS)
		// No internal scrolling: the host (a grouped form, an inspector) already
		// scrolls, and there is no focus effect needing room to overflow.
		VStack(spacing: 8) {
			ForEach(cameras) { camera in
				cameraRow(camera)
			}
			manualURLField
		}
#else
		ScrollView {
			VStack(spacing: 16) {
				ForEach(cameras) { camera in
					cameraRow(camera)
				}
				manualURLField
			}
			// `.card` grows and lifts the focused row (~1.1×) and the focus
			// effect draws outside the scroll view, so reserve a margin all
			// around for it to expand into instead of past the panel edge.
			.padding(.horizontal, 30)
			.padding(.vertical, 10)
		}
		// Fill the height the panel imposes (so the cameras tab matches the
		// other tabs); cap it when shown unconstrained (e.g. previews).
		.frame(maxHeight: .infinity)
#endif
	}

	@ViewBuilder
	func cameraRow(_ camera: ONVIFCamera) -> some View {
		Button {
			connect(to: camera)
		} label: {
			HStack(spacing: 12) {
				Image(systemName: "web.camera")
					.foregroundStyle(Color.panelAccent)
				VStack(alignment: .leading, spacing: 2) {
					// The camera's configured hostname, once GetHostname has
					// answered; the discovery scope name until then.
					Text(hostnames[camera.id] ?? camera.name)
						.font(.subheadline.weight(.semibold))
					Text(camera.ipAddress)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Spacer(minLength: 0)
				if connectingCameraID == camera.id {
					ProgressView()
				} else if isCurrent(camera) {
					Image(systemName: "checkmark")
						.font(.caption.weight(.semibold))
						.foregroundStyle(Color.panelAccent)
				}
			}
			.padding(12)
#if !os(tvOS)
			.background(
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.fill(Color.primary.opacity(0.06))
			)
#endif
			.contentShape(Rectangle())
		}
#if os(tvOS)
		.buttonStyle(.card)
#else
		.buttonStyle(.plain)
#endif
		.disabled(connectingCameraID != nil)
	}
}

// MARK: - Credential-change reconnect

private extension ONVIFCameraListView {

	/// React to a credential-source change by re-attempting the current
	/// selection's connection. A discovered camera is fully re-resolved over
	/// ONVIF (so the panel shows progress and any auth error); anything else —
	/// a manual URL, or a camera that has dropped off discovery — is simply
	/// re-tagged so the host re-authenticates the same URL.
	func reconnectForCredentialChange() {
		guard let host = currentSelection.wrappedValue?.url.host() else { return }
		if let camera = cameras.first(where: { $0.ipAddress == host }) {
			connect(to: camera)
		} else {
			retagCurrentSelection()
		}
	}

	/// Re-stamp the current selection with the active source's credentials,
	/// keeping its URL and name. The host's `authenticatedURL(managedCredentials:)`
	/// then yields a new URL, which restarts playback.
	func retagCurrentSelection() {
		guard let current = currentSelection.wrappedValue else { return }
		let updated = RTSPCameraSelection(url: current.url, name: current.name, credentials: selectedCredentials)
		if updated != current { currentSelection.wrappedValue = updated }
	}
}

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
/// writes it to `currentURL`; the camera matching `currentURL`'s host shows
/// a checkmark, including when the URL was set before the panel opened.
struct ONVIFCameraListView: View {

	/// A camera vanishing for this long is considered gone (~2 missed probe
	/// rounds plus margin).
	private static let cameraExpiry: TimeInterval = 10

	let currentURL: Binding<URL>

	@State private var username = ""
	@State private var password = ""
	@State private var discovered: [ONVIFCamera.ID: (camera: ONVIFCamera, lastSeen: Date)] = [:]
	@State private var hostnames: [ONVIFCamera.ID: String] = [:]
	@State private var hostnameRequests: Set<ONVIFCamera.ID> = []
	@State private var hasCompletedRound = false
	@State private var connectingCameraID: ONVIFCamera.ID?
	@State private var errorMessage: String?

	private var cameras: [ONVIFCamera] {
		discovered.values.map(\.camera).sorted { ($0.name, $0.ipAddress) < ($1.name, $1.ipAddress) }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			credentialFields
			if hasCompletedRound && cameras.isEmpty {
				Text(String(localized: "cameras.empty", bundle: .module))
					.font(.caption)
					.foregroundStyle(.secondary)
					.padding(.horizontal)
			}
			if let errorMessage {
				Text(errorMessage)
					.font(.caption)
					.foregroundStyle(.red)
					.padding(.horizontal)
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
	}

	// MARK: - Subviews

	private var credentialFields: some View {
		HStack(spacing: 10) {
			TextField(String(localized: "cameras.username", bundle: .module), text: $username)
				.textContentType(.username)
			SecureField(String(localized: "cameras.password", bundle: .module), text: $password)
				.textContentType(.password)
		}
#if !os(tvOS)
		.textFieldStyle(.roundedBorder)
#endif
#if os(iOS) || os(visionOS)
		.textInputAutocapitalization(.never)
		.autocorrectionDisabled()
#endif
		.padding(.horizontal)
	}

	private var cameraList: some View {
		ScrollView {
			VStack(spacing: 16) {
				ForEach(cameras) { camera in
					cameraRow(camera)
				}
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
	}

	@ViewBuilder
	private func cameraRow(_ camera: ONVIFCamera) -> some View {
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

	/// Whether the player's current URL points at this camera — true right
	/// after a successful selection here, but also when the client app was
	/// already configured with this camera's stream before the panel opened.
	private func isCurrent(_ camera: ONVIFCamera) -> Bool {
		currentURL.wrappedValue.host() == camera.ipAddress
	}

	// MARK: - Actions

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
				let credentials = ONVIFCredentials(username: username, password: password)
				let url = try await ONVIFDiscoveryService.streamURL(for: camera, credentials: credentials)
				currentURL.wrappedValue = url
			} catch {
				// A previously selected camera keeps playing on failure, so
				// its checkmark stays where it is.
				errorMessage = error.localizedDescription
			}
		}
	}
}

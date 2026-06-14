//
//  ONVIFDiscoveryService.swift
//  SwiftRTSPPlayer
//

import Foundation

/// Username/password pair for ONVIF requests (WS-Security UsernameToken) and
/// for the resulting RTSP stream URL.
public struct ONVIFCredentials: Sendable {
	public let username: String
	public let password: String

	public init(username: String, password: String) {
		self.username = username
		self.password = password
	}

	var isEmpty: Bool { username.isEmpty && password.isEmpty }
}

/// Errors surfaced by `ONVIFDiscoveryService`.
public enum ONVIFError: Error, LocalizedError {
	/// The HTTP request failed or returned a non-XML payload.
	case invalidResponse
	/// The credentials were rejected (`ter:NotAuthorized`). Distinct from
	/// `accountLocked` so the caller can avoid retrying into a lockout.
	case notAuthorized
	/// The camera locked the account after too many failed logins. Common on
	/// Dahua-based cameras (e.g. Lorex); the lock clears after a cooldown or a
	/// reboot, so retrying immediately only re-arms it.
	case accountLocked
	/// The camera answered with some other SOAP fault.
	case soapFault(reason: String)
	/// The camera returned an HTTP error status.
	case requestFailed(statusCode: Int)
	/// `GetProfiles` returned no media profile.
	case noProfiles
	/// `GetStreamUri` returned a string that is not a valid URL.
	case malformedStreamURL

	/// Classify a parsed SOAP fault into the most specific error case.
	init(fault: ONVIFDiscoveryService.SOAPFault) {
		// Dahua/Lorex firmware reports the lockout as a `NotAuthorized` fault
		// whose reason mentions the account being locked — detect it by the
		// reason text since the subcode alone can't tell it apart.
		if fault.reason.range(of: "lock", options: .caseInsensitive) != nil {
			self = .accountLocked
		} else if fault.subcode == "NotAuthorized" {
			self = .notAuthorized
		} else {
			self = .soapFault(reason: fault.reason)
		}
	}

	public var errorDescription: String? {
		switch self {
		case .invalidResponse:
			return String(localized: "error.onvif.invalidResponse", bundle: .module)
		case .notAuthorized:
			return String(localized: "error.onvif.notAuthorized", bundle: .module)
		case .accountLocked:
			return String(localized: "error.onvif.accountLocked", bundle: .module)
		case .soapFault(let reason):
			return reason.isEmpty
				? String(localized: "error.onvif.fault", bundle: .module)
				: reason
		case .requestFailed(let statusCode):
			return String(localized: "error.onvif.requestFailed \(statusCode)", bundle: .module)
		case .noProfiles:
			return String(localized: "error.onvif.noProfiles", bundle: .module)
		case .malformedStreamURL:
			return String(localized: "error.onvif.malformedStreamURL", bundle: .module)
		}
	}
}

/// Discovers ONVIF cameras on the local network (WS-Discovery) and resolves
/// their RTSP stream URLs (`GetProfiles` + `GetStreamUri`).
///
/// ```swift
/// for try await camera in ONVIFDiscoveryService.discoverCameras() {
///     let url = try await ONVIFDiscoveryService.streamURL(
///         for: camera,
///         credentials: ONVIFCredentials(username: "admin", password: "…")
///     )
/// }
/// ```
///
/// > Note: On iOS/tvOS, sending UDP broadcast requires the
/// > `com.apple.developer.networking.multicast` entitlement and the app must
/// > declare `NSLocalNetworkUsageDescription`. macOS only needs the outgoing
/// > network sandbox entitlement.
public enum ONVIFDiscoveryService {

	private static let wsDiscoveryPort: UInt16 = 3702
	private static let deviceNamespace = "http://www.onvif.org/ver10/device/wsdl"
	private static let mediaNamespace = "http://www.onvif.org/ver20/media/wsdl"
	private static let session = URLSession(configuration: .ephemeral)

	// MARK: - Discovery

	/// Broadcast a WS-Discovery probe and stream back each camera that answers,
	/// de-duplicated by IP address. The stream finishes after `timeout`.
	@MainActor
	public static func discoverCameras(timeout: Duration = .seconds(3)) -> AsyncThrowingStream<ONVIFCamera, Error> {
		let (stream, continuation) = AsyncThrowingStream.makeStream(of: ONVIFCamera.self)

		var seenAddresses = Set<String>()
		let connection = UDPBroadcastConnection { ipAddress, _, data in
			guard let camera = camera(fromProbeResponse: data, ipAddress: ipAddress),
						seenAddresses.insert(camera.ipAddress).inserted else { return }
			continuation.yield(camera)
		} errorHandler: { error in
			continuation.finish(throwing: error)
		}

		do {
			let probe = ONVIFSOAP.probeMessage()
			// The spec says multicast; plenty of cameras also (or only) answer
			// the limited-broadcast address, so probe both.
			try connection.send(probe, to: .wsDiscoveryMulticast(port: wsDiscoveryPort))
			try connection.send(probe, to: .broadcast(port: wsDiscoveryPort))
		} catch {
			connection.close()
			continuation.finish(throwing: error)
			return stream
		}

		let timeoutTask = Task { @MainActor in
			try? await Task.sleep(for: timeout)
			guard !Task.isCancelled else { return }
			connection.close()
			continuation.finish()
		}
		continuation.onTermination = { _ in
			timeoutTask.cancel()
			Task { @MainActor in connection.close() }
		}
		return stream
	}

	// MARK: - Device queries

	/// Hostname configured on the camera (`GetHostname` — no authentication
	/// required). Returns nil when the camera reports none.
	public static func hostname(for camera: ONVIFCamera) async throws -> String? {
		let body = ONVIFSOAP.query(namespace: deviceNamespace, action: "GetHostname")
		let data = try await post(body, to: camera.deviceService)
		return hostname(fromResponse: data)
	}

	// MARK: - Stream URL resolution

	/// Media profiles advertised by `camera`.
	public static func profiles(
		for camera: ONVIFCamera,
		credentials: ONVIFCredentials
	) async throws -> [ONVIFProfile] {
		let body = ONVIFSOAP.query(namespace: mediaNamespace, action: "GetProfiles", credentials: credentials)
		let data = try await post(body, to: camera.deviceService)
		return profiles(fromResponse: data)
	}

	/// RTSP URL for a specific profile, with the credentials embedded in the
	/// URL's userinfo so the player can authenticate against the camera.
	public static func streamURL(
		for camera: ONVIFCamera,
		profile: ONVIFProfile,
		credentials: ONVIFCredentials
	) async throws -> URL {
		let body = ONVIFSOAP.query(
			namespace: mediaNamespace,
			action: "GetStreamUri",
			credentials: credentials,
			params: [("Protocol", "RTSP"), ("ProfileToken", profile.token)]
		)
		let data = try await post(body, to: camera.deviceService)
		guard let url = streamURI(fromResponse: data) else { throw ONVIFError.malformedStreamURL }
		let normalized = normalizedHost(of: url, fallback: camera.ipAddress)
		return self.url(byInjecting: credentials, into: normalized)
	}

	/// RTSP URL of the camera's first media profile (usually the main stream).
	public static func streamURL(
		for camera: ONVIFCamera,
		credentials: ONVIFCredentials
	) async throws -> URL {
		guard let profile = try await profiles(for: camera, credentials: credentials).first else {
			throw ONVIFError.noProfiles
		}
		return try await streamURL(for: camera, profile: profile, credentials: credentials)
	}

	// MARK: - HTTP

	private static func post(_ body: String, to url: URL) async throws -> Data {
		var request = URLRequest(url: url, timeoutInterval: 10)
		request.httpMethod = "POST"
		request.httpBody = Data(body.utf8)
		request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")

		let (data, response) = try await session.data(for: request)
		guard let httpResponse = response as? HTTPURLResponse else { throw ONVIFError.invalidResponse }
		guard (200..<300).contains(httpResponse.statusCode) else {
			// Cameras report bad credentials (and lockouts) as a SOAP fault with
			// a 400/500 status — classify it when there is one.
			if let fault = fault(fromResponse: data) {
				throw ONVIFError(fault: fault)
			}
			throw ONVIFError.requestFailed(statusCode: httpResponse.statusCode)
		}
		return data
	}

	// MARK: - Response parsing (internal for tests)

	/// Build a camera from a WS-Discovery ProbeMatch response.
	static func camera(fromProbeResponse data: Data, ipAddress: String) -> ONVIFCamera? {
		guard let root = ONVIFXMLNode.parse(data),
					let probeMatch = root["Body"]?["ProbeMatches"]?["ProbeMatch"] else { return nil }

		// XAddrs can list several endpoints separated by whitespace — and the
		// advertised hosts are unreliable (empty `http://[]`, link-local IPv6,
		// stale IP). The probe response's source address is authoritative, so
		// keep an advertised URL only when its host matches the sender;
		// otherwise rebuild it around the sender, keeping scheme/port/path.
		let xAddrs = probeMatch["XAddrs"]?.text.split(whereSeparator: \.isWhitespace) ?? []
		let advertised = xAddrs.compactMap { URL(string: String($0)) }
		guard let deviceService = advertised.first(where: { $0.host() == ipAddress })
			?? advertised.lazy.compactMap({ url(byReplacingHost: ipAddress, in: $0) }).first
			?? defaultDeviceService(forHost: ipAddress)
		else { return nil }

		let scopes = probeMatch["Scopes"]?.text.split(whereSeparator: \.isWhitespace) ?? []
		let model = scopeValue(in: scopes, category: "hardware") ?? ""
		let name = scopeValue(in: scopes, category: "name") ?? model

		return ONVIFCamera(
			name: name.isEmpty ? ipAddress : name,
			model: model,
			ipAddress: ipAddress,
			deviceService: deviceService
		)
	}

	/// Extract the (percent-decoded) value of an `onvif://www.onvif.org/<category>/…` scope.
	private static func scopeValue(in scopes: [Substring], category: String) -> String? {
		let prefix = "onvif://www.onvif.org/\(category)/"
		guard let scope = scopes.first(where: { $0.hasPrefix(prefix) }) else { return nil }
		return String(scope.dropFirst(prefix.count)).removingPercentEncoding
	}

	/// Extract the hostname from a GetHostnameResponse.
	static func hostname(fromResponse data: Data) -> String? {
		guard let root = ONVIFXMLNode.parse(data),
					let name = root["Body"]?["GetHostnameResponse"]?["HostnameInformation"]?["Name"]?.text,
					!name.isEmpty else { return nil }
		return name
	}

	/// Extract the media profiles from a GetProfilesResponse.
	static func profiles(fromResponse data: Data) -> [ONVIFProfile] {
		guard let root = ONVIFXMLNode.parse(data) else { return [] }
		return root.descendants(named: "Profiles").compactMap { node in
			guard let token = node.attributes["token"] else { return nil }
			return ONVIFProfile(token: token, name: node["Name"]?.text ?? token)
		}
	}

	/// Extract the stream URL from a GetStreamUriResponse.
	static func streamURI(fromResponse data: Data) -> URL? {
		guard let root = ONVIFXMLNode.parse(data),
					let uri = root["Body"]?["GetStreamUriResponse"]?["Uri"]?.text else { return nil }
		return URL(string: uri)
	}

	/// A parsed SOAP 1.2 fault: its subcode local name (e.g. `NotAuthorized`)
	/// and human-readable reason text.
	struct SOAPFault {
		let subcode: String
		let reason: String
	}

	/// Parse a SOAP fault out of a response payload, if it is one.
	static func fault(fromResponse data: Data) -> SOAPFault? {
		guard let root = ONVIFXMLNode.parse(data),
					let fault = root["Body"]?["Fault"] else { return nil }
		let reason = fault.descendants(named: "Text").first?.text ?? ""
		// SOAP 1.2 nests the application subcode under Code/Subcode/Value;
		// fall back to the top-level Code/Value otherwise. The value carries a
		// namespace prefix ("ter:NotAuthorized") — keep only the local part.
		let codeValue = fault["Code"]?["Subcode"]?["Value"]?.text
			?? fault["Code"]?["Value"]?.text ?? ""
		let subcode = codeValue.split(separator: ":").last.map(String.init) ?? codeValue
		return SOAPFault(subcode: subcode, reason: reason)
	}

	/// Extract the human-readable reason of a SOAP fault, if the payload is one.
	static func faultReason(fromResponse data: Data) -> String? {
		fault(fromResponse: data)?.reason
	}

	/// Embed the credentials in the URL's userinfo (`rtsp://user:pass@host/…`).
	static func url(byInjecting credentials: ONVIFCredentials, into url: URL) -> URL {
		guard !credentials.isEmpty,
					var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
		components.user = credentials.username
		components.password = credentials.password
		return components.url ?? url
	}

	/// Rewrite the URL's host, keeping scheme, port, path and query.
	static func url(byReplacingHost host: String, in url: URL) -> URL? {
		guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
		components.host = host
		return components.url
	}

	/// Standard device service endpoint on a host that advertised no usable XAddrs.
	private static func defaultDeviceService(forHost host: String) -> URL? {
		var components = URLComponents()
		components.scheme = "http"
		components.host = host
		components.path = "/onvif/device_service"
		return components.url
	}

	/// Some cameras also return stream URLs with an empty host — substitute
	/// the camera's known address in that case.
	static func normalizedHost(of url: URL, fallback ipAddress: String) -> URL {
		guard (url.host() ?? "").isEmpty else { return url }
		return self.url(byReplacingHost: ipAddress, in: url) ?? url
	}
}

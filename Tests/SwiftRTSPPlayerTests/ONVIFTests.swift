import Foundation
import Testing
@testable import SwiftRTSPPlayer

// MARK: - ONVIF response parsing

@Suite("ONVIF response parsing")
struct ONVIFParsingTests {

	@Test("ProbeMatch response yields a camera")
	func probeMatch() {
		let xml = """
		<?xml version="1.0" encoding="UTF-8"?>
		<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope"
											 xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
			<SOAP-ENV:Body>
				<d:ProbeMatches>
					<d:ProbeMatch>
						<d:Scopes>onvif://www.onvif.org/type/video_encoder \
		onvif://www.onvif.org/name/Cam%20Glace onvif://www.onvif.org/hardware/IPC-HDW2431T</d:Scopes>
						<d:XAddrs>http://192.168.1.108/onvif/device_service \
		http://[fe80::1]/onvif/device_service</d:XAddrs>
					</d:ProbeMatch>
				</d:ProbeMatches>
			</SOAP-ENV:Body>
		</SOAP-ENV:Envelope>
		"""
		let camera = ONVIFDiscoveryService.camera(fromProbeResponse: Data(xml.utf8), ipAddress: "192.168.1.108")
		#expect(camera != nil)
		#expect(camera?.name == "Cam Glace")
		#expect(camera?.model == "IPC-HDW2431T")
		#expect(camera?.ipAddress == "192.168.1.108")
		#expect(camera?.deviceService == URL(string: "http://192.168.1.108/onvif/device_service"))
	}

	@Test("ProbeMatch without a name scope falls back to the hardware model")
	func probeMatchWithoutName() {
		let xml = """
		<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
								xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
			<e:Body>
				<d:ProbeMatches>
					<d:ProbeMatch>
						<d:Scopes>onvif://www.onvif.org/hardware/IPC-1234</d:Scopes>
						<d:XAddrs>http://10.0.0.5/onvif/device_service</d:XAddrs>
					</d:ProbeMatch>
				</d:ProbeMatches>
			</e:Body>
		</e:Envelope>
		"""
		let camera = ONVIFDiscoveryService.camera(fromProbeResponse: Data(xml.utf8), ipAddress: "10.0.0.5")
		#expect(camera?.name == "IPC-1234")
		#expect(camera?.model == "IPC-1234")
	}

	@Test("Empty advertised host is replaced by the responder's address")
	func emptyAdvertisedHost() {
		// Some cameras advertise a literally empty host in XAddrs.
		let xml = """
		<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
								xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
			<e:Body>
				<d:ProbeMatches>
					<d:ProbeMatch>
						<d:Scopes>onvif://www.onvif.org/hardware/IPC-1234</d:Scopes>
						<d:XAddrs>http://[]/onvif/device_service</d:XAddrs>
					</d:ProbeMatch>
				</d:ProbeMatches>
			</e:Body>
		</e:Envelope>
		"""
		let camera = ONVIFDiscoveryService.camera(fromProbeResponse: Data(xml.utf8), ipAddress: "192.168.1.20")
		#expect(camera?.deviceService == URL(string: "http://192.168.1.20/onvif/device_service"))
	}

	@Test("The XAddr matching the responder is preferred over link-local IPv6")
	func ipv6AdvertisedFirst() {
		let xml = """
		<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
								xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
			<e:Body>
				<d:ProbeMatches>
					<d:ProbeMatch>
						<d:Scopes>onvif://www.onvif.org/hardware/IPC-1234</d:Scopes>
						<d:XAddrs>http://[fe80::1]/onvif/device_service \
		http://192.168.1.30:8080/onvif/device_service</d:XAddrs>
					</d:ProbeMatch>
				</d:ProbeMatches>
			</e:Body>
		</e:Envelope>
		"""
		let camera = ONVIFDiscoveryService.camera(fromProbeResponse: Data(xml.utf8), ipAddress: "192.168.1.30")
		#expect(camera?.deviceService == URL(string: "http://192.168.1.30:8080/onvif/device_service"))
	}

	@Test("Missing XAddrs falls back to the standard device service path")
	func missingXAddrs() {
		let xml = """
		<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
								xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
			<e:Body>
				<d:ProbeMatches>
					<d:ProbeMatch>
						<d:Scopes>onvif://www.onvif.org/hardware/IPC-1234</d:Scopes>
					</d:ProbeMatch>
				</d:ProbeMatches>
			</e:Body>
		</e:Envelope>
		"""
		let camera = ONVIFDiscoveryService.camera(fromProbeResponse: Data(xml.utf8), ipAddress: "10.0.0.9")
		#expect(camera?.deviceService == URL(string: "http://10.0.0.9/onvif/device_service"))
	}

	@Test("Stream URL with an empty host gets the camera's address")
	func emptyStreamHost() {
		let url = URL(string: "rtsp://[]:554/cam/realmonitor?channel=1")!
		let fixed = ONVIFDiscoveryService.normalizedHost(of: url, fallback: "192.168.1.108")
		#expect(fixed == URL(string: "rtsp://192.168.1.108:554/cam/realmonitor?channel=1"))

		let untouched = URL(string: "rtsp://192.168.1.5/stream")!
		#expect(ONVIFDiscoveryService.normalizedHost(of: untouched, fallback: "192.168.1.108") == untouched)
	}

	@Test("Non-ONVIF payload yields no camera")
	func notAProbeMatch() {
		#expect(ONVIFDiscoveryService.camera(fromProbeResponse: Data("not xml".utf8), ipAddress: "1.2.3.4") == nil)
		let otherXML = "<Envelope><Body><Other/></Body></Envelope>"
		#expect(ONVIFDiscoveryService.camera(fromProbeResponse: Data(otherXML.utf8), ipAddress: "1.2.3.4") == nil)
	}

	@Test("GetProfilesResponse yields tokens and names")
	func profiles() {
		let xml = """
		<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
			<s:Body>
				<trt:GetProfilesResponse xmlns:trt="http://www.onvif.org/ver20/media/wsdl">
					<trt:Profiles token="MainStream" fixed="true">
						<tt:Name xmlns:tt="http://www.onvif.org/ver10/schema">Main</tt:Name>
					</trt:Profiles>
					<trt:Profiles token="SubStream" fixed="true">
						<tt:Name xmlns:tt="http://www.onvif.org/ver10/schema">Sub</tt:Name>
					</trt:Profiles>
				</trt:GetProfilesResponse>
			</s:Body>
		</s:Envelope>
		"""
		let profiles = ONVIFDiscoveryService.profiles(fromResponse: Data(xml.utf8))
		#expect(profiles.count == 2)
		#expect(profiles.first?.token == "MainStream")
		#expect(profiles.first?.name == "Main")
		#expect(profiles.last?.token == "SubStream")
	}

	@Test("GetHostnameResponse yields the configured hostname")
	func hostname() {
		let xml = """
		<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
			<s:Body>
				<tds:GetHostnameResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
					<tds:HostnameInformation>
						<tt:FromDHCP xmlns:tt="http://www.onvif.org/ver10/schema">false</tt:FromDHCP>
						<tt:Name xmlns:tt="http://www.onvif.org/ver10/schema">cam-curling</tt:Name>
					</tds:HostnameInformation>
				</tds:GetHostnameResponse>
			</s:Body>
		</s:Envelope>
		"""
		#expect(ONVIFDiscoveryService.hostname(fromResponse: Data(xml.utf8)) == "cam-curling")

		let noName = """
		<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
			<s:Body>
				<tds:GetHostnameResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
					<tds:HostnameInformation>
						<tt:FromDHCP xmlns:tt="http://www.onvif.org/ver10/schema">true</tt:FromDHCP>
					</tds:HostnameInformation>
				</tds:GetHostnameResponse>
			</s:Body>
		</s:Envelope>
		"""
		#expect(ONVIFDiscoveryService.hostname(fromResponse: Data(noName.utf8)) == nil)
	}

	@Test("GetStreamUriResponse yields the stream URL")
	func streamURI() {
		let xml = """
		<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
			<s:Body>
				<trt:GetStreamUriResponse xmlns:trt="http://www.onvif.org/ver20/media/wsdl">
					<trt:Uri>rtsp://192.168.1.108:554/cam/realmonitor?channel=1</trt:Uri>
				</trt:GetStreamUriResponse>
			</s:Body>
		</s:Envelope>
		"""
		let url = ONVIFDiscoveryService.streamURI(fromResponse: Data(xml.utf8))
		#expect(url == URL(string: "rtsp://192.168.1.108:554/cam/realmonitor?channel=1"))
	}

	@Test("SOAP fault reason is extracted")
	func faultReason() {
		let xml = """
		<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
			<s:Body>
				<s:Fault>
					<s:Reason><s:Text xml:lang="en">Sender not authorized</s:Text></s:Reason>
				</s:Fault>
			</s:Body>
		</s:Envelope>
		"""
		#expect(ONVIFDiscoveryService.faultReason(fromResponse: Data(xml.utf8)) == "Sender not authorized")
		let noFault = "<Envelope><Body><GetProfilesResponse/></Body></Envelope>"
		#expect(ONVIFDiscoveryService.faultReason(fromResponse: Data(noFault.utf8)) == nil)
	}

	@Test("Credentials are injected into the stream URL")
	func credentialInjection() {
		let url = URL(string: "rtsp://192.168.1.108:554/stream?channel=1")!
		let credentials = ONVIFCredentials(username: "admin", password: "p@ss:word")
		let result = ONVIFDiscoveryService.url(byInjecting: credentials, into: url)
		#expect(result.user(percentEncoded: false) == "admin")
		#expect(result.password(percentEncoded: false) == "p@ss:word")
		#expect(result.host() == "192.168.1.108")
		#expect(result.port == 554)

		let empty = ONVIFCredentials(username: "", password: "")
		#expect(ONVIFDiscoveryService.url(byInjecting: empty, into: url) == url)
	}
}

// MARK: - WS-Security header

@Suite("ONVIF SOAP")
struct ONVIFSOAPTests {

	@Test("Security header carries the UsernameToken fields")
	func passwordDigest() {
		let nonce = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
		let created = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
		let header = ONVIFSOAP.securityHeader(
			credentials: ONVIFCredentials(username: "admin", password: "secret"),
			nonce: nonce,
			created: created
		)
		#expect(header.contains("<Username>admin</Username>"))
		#expect(header.contains("<Nonce EncodingType="))
		#expect(header.contains(nonce.base64EncodedString()))
		#expect(header.contains("<Created"))
		#expect(header.contains("2026-01-01T00:00:00Z"))
		#expect(header.contains("<Password") && header.contains("PasswordDigest"))
	}

	@Test("Username is XML-escaped")
	func usernameEscaping() {
		let header = ONVIFSOAP.securityHeader(
			credentials: ONVIFCredentials(username: "a<b&c", password: "x")
		)
		#expect(header.contains("<Username>a&lt;b&amp;c</Username>"))
	}

	@Test("Probe message declares the NetworkVideoTransmitter type")
	func probeMessage() {
		let probe = ONVIFSOAP.probeMessage()
		#expect(probe.contains("<d:Types>dn:NetworkVideoTransmitter</d:Types>"))
		#expect(probe.contains("uuid:"))
	}
}

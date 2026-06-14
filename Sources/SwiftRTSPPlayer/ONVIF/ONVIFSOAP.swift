//
//  ONVIFSOAP.swift
//  SwiftRTSPPlayer
//

import CryptoKit
import Foundation

/// Builds the SOAP envelopes used by ONVIF discovery and device queries.
enum ONVIFSOAP {

	/// WS-Discovery probe asking every NetworkVideoTransmitter on the segment
	/// to identify itself.
	static func probeMessage() -> String {
		"""
		<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
								xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
								xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
								xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
			<e:Header>
				<w:MessageID>uuid:\(UUID().uuidString.lowercased())</w:MessageID>
				<w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
				<w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
			</e:Header>
			<e:Body>
				<d:Probe>
					<d:Types>dn:NetworkVideoTransmitter</d:Types>
				</d:Probe>
			</e:Body>
		</e:Envelope>
		"""
	}

	/// SOAP envelope for a device/media service request, optionally carrying a
	/// WS-Security UsernameToken header (PasswordDigest profile).
	static func query(
		namespace: String,
		action: String,
		credentials: ONVIFCredentials? = nil,
		params: [(name: String, value: String)] = []
	) -> String {
		let header = credentials.map { securityHeader(credentials: $0) } ?? ""
		let paramsXML = params.map { "<\($0.name)>\($0.value)</\($0.name)>" }.joined(separator: "\n")
		return """
		<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
			<s:Header>
				\(header)
			</s:Header>
			<s:Body xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
				<\(action) xmlns="\(namespace)">
					\(paramsXML)
				</\(action)>
			</s:Body>
		</s:Envelope>
		"""
	}

	/// WS-Security UsernameToken header. The digest is
	/// `Base64(SHA1(nonce + created + password))` per the
	/// Username Token Profile 1.0.
	static func securityHeader(
		credentials: ONVIFCredentials,
		nonce rawNonce: Data = Data((0..<20).map { _ in UInt8.random(in: .min ... .max) }),
		created: Date = Date()
	) -> String {
		let createdString = ISO8601DateFormatter().string(from: created)

		var hasher = Insecure.SHA1()
		hasher.update(data: rawNonce)
		hasher.update(data: Data(createdString.utf8))
		hasher.update(data: Data(credentials.password.utf8))
		let digest = Data(hasher.finalize()).base64EncodedString()

		let prefixNS = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss"
		return """
		<Security s:mustUnderstand="1" xmlns="\(prefixNS)-wssecurity-secext-1.0.xsd">
			<UsernameToken>
				<Username>\(escape(credentials.username))</Username>
				<Password Type="\(prefixNS)-username-token-profile-1.0#PasswordDigest">\(digest)</Password>
				<Nonce EncodingType="\(prefixNS)-soap-message-security-1.0#Base64Binary">\(rawNonce.base64EncodedString())</Nonce>
				<Created xmlns="\(prefixNS)-wssecurity-utility-1.0.xsd">\(createdString)</Created>
			</UsernameToken>
		</Security>
		"""
	}

	/// Escape the XML special characters in a text node.
	private static func escape(_ value: String) -> String {
		value
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
	}
}

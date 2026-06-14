//
//  UDPBroadcastConnection.swift
//  SwiftRTSPPlayer
//
//  Adapted from UDPBroadcastConnection by Gunter Hager (MIT).
//  Copyright © 2016 Gunter Hager. All rights reserved.
//

import Darwin
import Foundation
import OSLog

private let osLog = Logger(subsystem: "SwiftRTSPPlayer", category: "udp_broadcast")

/// Forwards to os_log only when `UDPBroadcastConnection.isLoggingEnabled` is on.
/// The message is built lazily so disabled logging costs nothing.
private struct GatedLog {
	func debug(_ message: @autoclosure () -> String) {
		guard UDPBroadcastConnection.isLoggingEnabled else { return }
		let text = message()
		osLog.debug("\(text)")
	}
}

private let log = GatedLog()

/// A UDP socket that sends datagrams to broadcast/multicast addresses and
/// listens for unicast replies on the same (ephemeral) local port. Used for
/// ONVIF WS-Discovery probes. The socket is created lazily on first send and
/// reads are dispatched on the main queue, so the whole object stays on the
/// main actor.
@MainActor
final class UDPBroadcastConnection {

	/// Verbose UDP socket logging is off by default — ONVIF WS-Discovery emits a
	/// per-datagram stream of log lines that can flood os_log and make Xcode's
	/// console unresponsive. Set this to `true` while debugging.
	public nonisolated(unsafe) static var isLoggingEnabled = false

	enum ConnectionError: Error {
		case createSocketFailed
		case enableBroadcastFailed
		case messageEncodingFailed
		case sendingMessageFailed(code: Int32)
		case receivedEndOfFile
		case receiveFailed(code: Int32)
	}

	/// Destination of an outgoing datagram.
	struct Destination {
		let address: in_addr
		let port: UInt16

		/// Limited broadcast address (255.255.255.255).
		static func broadcast(port: UInt16) -> Destination {
			Destination(address: in_addr(s_addr: 0xffffffff), port: port)
		}

		/// The WS-Discovery multicast group (239.255.255.250).
		static func wsDiscoveryMulticast(port: UInt16) -> Destination {
			Destination(address: in_addr(s_addr: inet_addr("239.255.255.250")), port: port)
		}
	}

	/// Handles an incoming UDP packet: source IP address, source port, payload.
	typealias ReceiveHandler = (_ ipAddress: String, _ port: Int, _ response: Data) -> Void
	/// Handles errors encountered while receiving packets.
	typealias ErrorHandler = (_ error: ConnectionError) -> Void

	private let handler: ReceiveHandler
	private let errorHandler: ErrorHandler?
	private var responseSource: DispatchSourceRead?

	init(handler: @escaping ReceiveHandler, errorHandler: ErrorHandler? = nil) {
		self.handler = handler
		self.errorHandler = errorHandler
	}

	deinit {
		// Last reference is gone; the dispatch source's cancel handler closes
		// the socket. Safe outside the actor — nothing else can touch us now.
		responseSource?.cancel()
	}

	// MARK: Interface

	/// Send `message` (UTF-8) to `destination`, creating the socket if needed.
	func send(_ message: String, to destination: Destination) throws {
		guard let data = message.data(using: .utf8) else { throw ConnectionError.messageEncodingFailed }
		try send(data, to: destination)
	}

	/// Send raw data to `destination`, creating the socket if needed.
	func send(_ data: Data, to destination: Destination) throws {
		if responseSource == nil {
			try createSocket()
		}
		guard let source = responseSource else { return }

		var address = sockaddr_in(
			sin_len: __uint8_t(MemoryLayout<sockaddr_in>.size),
			sin_family: sa_family_t(AF_INET),
			sin_port: destination.port.bigEndian,
			sin_addr: destination.address,
			sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
		)

		let udpSocket = Int32(source.handle)
		let addressLength = socklen_t(address.sin_len)
		let sent = data.withUnsafeBytes { payload in
			withUnsafePointer(to: &address) { pointer -> Int in
				let memory = UnsafeRawPointer(pointer).bindMemory(to: sockaddr.self, capacity: 1)
				return sendto(udpSocket, payload.baseAddress, data.count, 0, memory, addressLength)
			}
		}

		guard sent > 0 else {
			if let errorString = errnoDescription() {
				log.debug("UDP connection failed to send data: \(errorString)")
			}
			close()
			throw ConnectionError.sendingMessageFailed(code: errno)
		}
		log.debug("UDP connection sent \(sent) bytes")
	}

	/// Close the socket. The connection can be reused — the next send reopens it.
	func close() {
		responseSource?.cancel()
		responseSource = nil
	}

	// MARK: Socket lifecycle

	private func createSocket() throws {
		let newSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
		guard newSocket > 0 else { throw ConnectionError.createSocketFailed }

		// Enable broadcast on socket
		var broadcastEnable = Int32(1)
		let ret = setsockopt(
			newSocket, SOL_SOCKET, SO_BROADCAST,
			&broadcastEnable, socklen_t(MemoryLayout<UInt32>.size)
		)
		if ret == -1 {
			log.debug("Couldn't enable broadcast on socket")
			Darwin.close(newSocket)
			throw ConnectionError.enableBroadcastFailed
		}

		// Disable the global SIGPIPE handler so the app doesn't crash on a
		// blocked send while suspended.
		var noSigPipe: Int32 = 1
		setsockopt(newSocket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

		let newResponseSource = DispatchSource.makeReadSource(fileDescriptor: newSocket, queue: .main)
		newResponseSource.setCancelHandler {
			log.debug("Closing UDP socket")
			let udpSocket = Int32(newResponseSource.handle)
			shutdown(udpSocket, SHUT_RDWR)
			Darwin.close(udpSocket)
		}
		newResponseSource.setEventHandler { [weak self] in
			// The read source is scheduled on the main queue, so hopping back
			// onto the main actor is a no-op.
			MainActor.assumeIsolated {
				self?.handleIncomingPacket()
			}
		}
		newResponseSource.resume()
		responseSource = newResponseSource
	}

	// MARK: Receiving

	private func handleIncomingPacket() {
		guard let source = responseSource else { return }

		var socketAddress = sockaddr_storage()
		var socketAddressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
		var response = [UInt8](repeating: 0, count: 4096)
		let udpSocket = Int32(source.handle)
		let bytesRead = withUnsafeMutablePointer(to: &socketAddress) { addressPointer in
			response.withUnsafeMutableBufferPointer { responsePointer in
				recvfrom(
					udpSocket, responsePointer.baseAddress, responsePointer.count, 0,
					UnsafeMutableRawPointer(addressPointer).bindMemory(to: sockaddr.self, capacity: 1),
					&socketAddressLength
				)
			}
		}

		guard bytesRead > 0 else {
			close()
			if bytesRead == 0 {
				log.debug("recvfrom returned EOF")
				errorHandler?(.receivedEndOfFile)
			} else {
				if let errorString = errnoDescription() {
					log.debug("recvfrom failed: \(errorString)")
				}
				errorHandler?(.receiveFailed(code: errno))
			}
			return
		}

		guard let endpoint = withUnsafePointer(to: &socketAddress, {
			let addressPointer = UnsafeRawPointer($0).bindMemory(to: sockaddr.self, capacity: 1)
			return Self.endpoint(fromSocketAddress: addressPointer)
		}) else {
			log.debug("Failed to get the address and port from the socket address received from recvfrom")
			close()
			return
		}

		log.debug("""
		UDP connection received \(bytesRead) bytes from \
		\(endpoint.host):\(endpoint.port)
		""")
		handler(endpoint.host, endpoint.port, Data(response[0..<bytesRead]))
	}

	// MARK: Helpers

	/// Convert a sockaddr structure into an IP address string and port.
	private static func endpoint(fromSocketAddress pointer: UnsafePointer<sockaddr>) -> (host: String, port: Int)? {
		switch Int32(pointer.pointee.sa_family) {
		case AF_INET:
			var address = UnsafeRawPointer(pointer).load(as: sockaddr_in.self)
			let length = Int(INET_ADDRSTRLEN) + 2
			var buffer = [CChar](repeating: 0, count: length)
			if inet_ntop(AF_INET, &address.sin_addr, &buffer, socklen_t(length)) != nil,
				 let host = string(fromNullTerminated: buffer) {
				return (host, Int(UInt16(bigEndian: address.sin_port)))
			}
			return nil

		case AF_INET6:
			var address = UnsafeRawPointer(pointer).load(as: sockaddr_in6.self)
			let length = Int(INET6_ADDRSTRLEN) + 2
			var buffer = [CChar](repeating: 0, count: length)
			if inet_ntop(AF_INET6, &address.sin6_addr, &buffer, socklen_t(length)) != nil,
				 let host = string(fromNullTerminated: buffer) {
				return (host, Int(UInt16(bigEndian: address.sin6_port)))
			}
			return nil

		default:
			return nil
		}
	}

	private static func string(fromNullTerminated buffer: [CChar]) -> String? {
		let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
		return String(validating: bytes, as: UTF8.self)
	}
}

/// `strerror(errno)` as a Swift string.
private func errnoDescription() -> String? {
	strerror(errno).flatMap { String(validatingCString: $0) }
}

//
//  FFmpegLog.swift
//  SwiftRTSPPlayer
//

import Foundation
import FFmpeg
import os

private let log = Logger(subsystem: "SwiftRTSPPlayer", category: "FFmpeg")

// Strip `user[:pass]@` userinfo from any URL embedded in `text`. RTSP URLs
// routinely carry credentials and FFmpeg cheerfully echoes the full URL into
// log lines (connection attempts, auth failures, error contexts). Without
// this filter those credentials would land verbatim in os_log / sysdiagnose.
private let credentialRegex: NSRegularExpression? = {
	try? NSRegularExpression(pattern: #"([a-zA-Z][a-zA-Z0-9+.-]*://)[^@\s/]+@"#)
}()

func redactCredentials(in text: String) -> String {
	guard let credentialRegex else { return text }
	let range = NSRange(text.startIndex..., in: text)
	return credentialRegex.stringByReplacingMatches(
		in: text,
		options: [],
		range: range,
		withTemplate: "$1***@"
	)
}

public enum FFmpegLog {
	// FFmpeg emits a high volume of log lines on RTSP streams; left running,
	// it can flood os_log and make Xcode's console unresponsive. Logging is
	// therefore off by default — set `FFmpegLog.isEnabled = true` to forward
	// FFmpeg output to os_log while debugging.
	public nonisolated(unsafe) static var isEnabled = false

	// Reading `install` runs the closure exactly once (Swift guarantees
	// thread-safe one-shot initialisation for static stored properties).
	static let install: Void = {
		av_log_set_callback { ptr, level, fmt, varlist in
			guard isEnabled else { return }
			guard let fmt, let varlist else { return }
			var buffer = [CChar](repeating: 0, count: 1024)
			var printPrefix: Int32 = 1
			_ = av_log_format_line2(
				ptr,
				level,
				fmt,
				varlist,
				&buffer,
				Int32(buffer.count),
				&printPrefix
			)
			let raw = String(cString: buffer)
				.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !raw.isEmpty else { return }
			let msg = redactCredentials(in: raw)

			switch level {
			case ..<AV_LOG_FATAL:
				log.fault("\(msg, privacy: .public)")
			case ..<AV_LOG_WARNING:
				log.error("\(msg, privacy: .public)")
			case ..<AV_LOG_INFO:
				log.notice("\(msg, privacy: .public)")
			case ..<AV_LOG_VERBOSE:
				log.info("\(msg, privacy: .public)")
			default:
				log.debug("\(msg, privacy: .public)")
			}
		}
	}()
}

//
//  IdleTimerCoordinator.swift
//  SwiftRTSPPlayer
//

#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import IOKit.pwr_mgt
#endif

#if os(iOS) || os(tvOS) || os(macOS)

// Reference-counts active streams so the display stays awake while any
// RTSPMetalView is playing, and reverts once the last one stops.
@MainActor
enum IdleTimerCoordinator {
	private static var activeCount = 0
	#if os(macOS)
	private static var assertionID: IOPMAssertionID = 0
	#endif

	static func acquire() {
		activeCount += 1
		guard activeCount == 1 else { return }
		#if os(iOS) || os(tvOS)
		UIApplication.shared.isIdleTimerDisabled = true
		#elseif os(macOS)
		IOPMAssertionCreateWithName(
			kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
			IOPMAssertionLevel(kIOPMAssertionLevelOn),
			"SwiftRTSPPlayer streaming" as CFString,
			&assertionID
		)
		#endif
	}

	static func release() {
		guard activeCount > 0 else { return }
		activeCount -= 1
		guard activeCount == 0 else { return }
		#if os(iOS) || os(tvOS)
		UIApplication.shared.isIdleTimerDisabled = false
		#elseif os(macOS)
		IOPMAssertionRelease(assertionID)
		assertionID = 0
		#endif
	}
}

#endif

//
//  RTSPPlaybackState.swift
//  SwiftRTSPPlayer
//

public enum RTSPPlaybackState: Equatable, Sendable {
	case stopped
	case noSource
	case connecting
	case playing
	case failed(String)
}

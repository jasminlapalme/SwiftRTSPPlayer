//
//  RTSPPlaybackState.swift
//  SwiftRTSPPlayer
//

public enum RTSPPlaybackState: Equatable, Sendable {
	case stopped
	case connecting
	case playing
	case failed(String)
}

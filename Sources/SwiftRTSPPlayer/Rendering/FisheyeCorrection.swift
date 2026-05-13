//
//  FisheyeCorrection.swift
//  SwiftRTSPPlayer
//

import CoreGraphics

/// Fisheye / wide-angle lens undistortion (OpenCV-style polynomial in θ).
///
/// Wide-angle security cameras (e.g. Lorex 4K Bullet, ~110-130° FOV) capture
/// images where straight lines bow outward — a polynomial in `r` (Brown-Conrady)
/// converges poorly at these angles. This model parameterizes the correction in
/// `θ = atan(r)` which handles wide FOV cleanly:
///
///     θ_d = θ · (1 + k1·θ² + k2·θ⁴ + k3·θ⁶ + k4·θ⁸)
///
/// Applied as a multiplicative factor on the source radius, so all coefficients
/// at zero leaves the image untouched. Aspect ratio is compensated by the
/// renderer so the correction is truly radial regardless of frame dimensions.
///
/// Calibration: increase `k1` first (typical range ±1), then add `k2` for fine
/// shape. `k3`/`k4` are usually only needed for extreme fisheye. The correction
/// leaves "pinched" black corners; combine with `RTSPPlayerView.scale` to crop.
public struct FisheyeCorrection: Equatable, Sendable, Codable {
	public var k1v: CGFloat
	public var k2v: CGFloat
	public var k3v: CGFloat
	public var k4v: CGFloat

	public init(k1v: CGFloat = 0, k2v: CGFloat = 0, k3v: CGFloat = 0, k4v: CGFloat = 0) {
		self.k1v = k1v
		self.k2v = k2v
		self.k3v = k3v
		self.k4v = k4v
	}

	public static let identity = FisheyeCorrection()
}

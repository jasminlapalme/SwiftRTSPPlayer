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
///
/// Straightening also stretches the borders past the frame, where they would be
/// lost: `expansion` zooms the corrected picture out by that factor so they come
/// back into view, inside the same frame.
public struct FisheyeCorrection: Equatable, Sendable, Codable {
	public var k1v: CGFloat
	public var k2v: CGFloat
	public var k3v: CGFloat
	public var k4v: CGFloat
	/// How far the corrected picture is zoomed out: 1 keeps it as is, 1.5 shows half as much again each way.
	public var expansion: CGFloat

	public init(
		k1v: CGFloat = 0,
		k2v: CGFloat = 0,
		k3v: CGFloat = 0,
		k4v: CGFloat = 0,
		expansion: CGFloat = 1
	) {
		self.k1v = k1v
		self.k2v = k2v
		self.k3v = k3v
		self.k4v = k4v
		self.expansion = expansion
	}

	public static let identity = FisheyeCorrection()

	private enum CodingKeys: String, CodingKey {
		case k1v, k2v, k3v, k4v, expansion
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		k1v = try container.decode(CGFloat.self, forKey: .k1v)
		k2v = try container.decode(CGFloat.self, forKey: .k2v)
		k3v = try container.decode(CGFloat.self, forKey: .k3v)
		k4v = try container.decode(CGFloat.self, forKey: .k4v)
		// Saved before the expansion existed: those framings were made without one.
		expansion = try container.decodeIfPresent(CGFloat.self, forKey: .expansion) ?? 1
	}
}

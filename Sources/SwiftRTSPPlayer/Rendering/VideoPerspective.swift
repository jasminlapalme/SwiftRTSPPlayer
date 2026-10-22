//
//  VideoPerspective.swift
//  SwiftRTSPPlayer
//

import CoreGraphics
import simd

/// Where each corner of the frame falls in the fisheye-corrected picture, in unit coordinates from the top left.
public struct VideoPerspective: Equatable, Sendable, Codable {
	public var topLeft: CGPoint
	public var topRight: CGPoint
	public var bottomRight: CGPoint
	public var bottomLeft: CGPoint

	public init(
		topLeft: CGPoint = CGPoint(x: 0, y: 0),
		topRight: CGPoint = CGPoint(x: 1, y: 0),
		bottomRight: CGPoint = CGPoint(x: 1, y: 1),
		bottomLeft: CGPoint = CGPoint(x: 0, y: 1)
	) {
		self.topLeft = topLeft
		self.topRight = topRight
		self.bottomRight = bottomRight
		self.bottomLeft = bottomLeft
	}

	public static let identity = VideoPerspective()

	/// How far an editor lets a corner go: half a picture past each edge.
	public static let editableRange: ClosedRange<CGFloat> = -0.5...1.5

	enum Corner: CaseIterable {
		case topLeft, topRight, bottomRight, bottomLeft
	}

	subscript(corner: Corner) -> CGPoint {
		get {
			switch corner {
			case .topLeft: topLeft
			case .topRight: topRight
			case .bottomRight: bottomRight
			case .bottomLeft: bottomLeft
			}
		}
		set {
			switch corner {
			case .topLeft: topLeft = newValue
			case .topRight: topRight = newValue
			case .bottomRight: bottomRight = newValue
			case .bottomLeft: bottomLeft = newValue
			}
		}
	}

	/// Frame to picture coordinates with h33 = 1; `nil` when three corners line up.
	var homography: simd_double3x3? {
		let frame = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
		let picture = [topLeft, topRight, bottomRight, bottomLeft]

		// Two rows per correspondence, the right-hand side in the last column.
		var rows: [[Double]] = []
		for (source, target) in zip(frame, picture) {
			let fromX = Double(source.x), fromY = Double(source.y)
			let toX = Double(target.x), toY = Double(target.y)
			rows.append([fromX, fromY, 1, 0, 0, 0, -toX * fromX, -toX * fromY, toX])
			rows.append([0, 0, 0, fromX, fromY, 1, -toY * fromX, -toY * fromY, toY])
		}

		// Gauss-Jordan with partial pivoting.
		for column in 0..<8 {
			guard let pivot = (column..<8).max(by: { abs(rows[$0][column]) < abs(rows[$1][column]) }),
				abs(rows[pivot][column]) > 1e-12
			else { return nil }
			rows.swapAt(column, pivot)
			for row in 0..<8 where row != column {
				let factor = rows[row][column] / rows[column][column]
				for index in column..<9 {
					rows[row][index] -= factor * rows[column][index]
				}
			}
		}
		let entries = (0..<8).map { rows[$0][8] / rows[$0][$0] }

		let homography = simd_double3x3(rows: [
			SIMD3(entries[0], entries[1], entries[2]),
			SIMD3(entries[3], entries[4], entries[5]),
			SIMD3(entries[6], entries[7], 1)
		])
		// The system can still be solvable when the quad is flat; the matrix then folds the plane.
		return abs(homography.determinant) > 1e-12 ? homography : nil
	}

	/// The matrix the shader takes; a degenerate quad draws the picture as is rather than a black frame.
	var shaderHomography: simd_float3x3 {
		guard let homography else { return matrix_identity_float3x3 }
		return simd_float3x3(columns: (
			SIMD3<Float>(homography.columns.0),
			SIMD3<Float>(homography.columns.1),
			SIMD3<Float>(homography.columns.2)
		))
	}

	/// Where a point of the frame lands in the picture; `nil` when it falls behind the horizon.
	func map(_ point: CGPoint) -> CGPoint? {
		guard let homography else { return nil }
		let projected = homography * SIMD3(Double(point.x), Double(point.y), 1)
		guard projected.z > 0 else { return nil }
		return CGPoint(x: projected.x / projected.z, y: projected.y / projected.z)
	}
}

import Foundation
import simd
import Testing
@testable import SwiftRTSPPlayer

@Suite("VideoPerspective")
struct VideoPerspectiveTests {

	/// The trapezoid of a sheet of ice filmed slightly off vertical.
	private let trapezoid = VideoPerspective(
		topLeft: CGPoint(x: 0.12, y: 0.08),
		topRight: CGPoint(x: 0.86, y: 0.10),
		bottomRight: CGPoint(x: 0.90, y: 0.93),
		bottomLeft: CGPoint(x: 0.09, y: 0.90)
	)

	private func isClose(_ lhs: CGPoint?, _ rhs: CGPoint) -> Bool {
		guard let lhs else { return false }
		return abs(lhs.x - rhs.x) < 1e-9 && abs(lhs.y - rhs.y) < 1e-9
	}

	@Test("The identity gives the identity homography")
	func identityHomography() throws {
		let homography = try #require(VideoPerspective.identity.homography)
		#expect(homography == matrix_identity_double3x3)
	}

	@Test("Each corner of the frame lands on its point of the picture")
	func sendsTheCornersExactly() {
		#expect(isClose(trapezoid.map(CGPoint(x: 0, y: 0)), trapezoid.topLeft))
		#expect(isClose(trapezoid.map(CGPoint(x: 1, y: 0)), trapezoid.topRight))
		#expect(isClose(trapezoid.map(CGPoint(x: 1, y: 1)), trapezoid.bottomRight))
		#expect(isClose(trapezoid.map(CGPoint(x: 0, y: 1)), trapezoid.bottomLeft))
	}

	@Test("The mapping is projective, not bilinear: the frame's diagonals meet where the quad's do")
	func keepsDiagonalsIntersecting() throws {
		let start = trapezoid.topLeft, end = trapezoid.bottomRight
		let other = trapezoid.topRight, otherEnd = trapezoid.bottomLeft
		let denominator = (start.x - end.x) * (other.y - otherEnd.y) - (start.y - end.y) * (other.x - otherEnd.x)
		let numerator = (start.x - other.x) * (other.y - otherEnd.y) - (start.y - other.y) * (other.x - otherEnd.x)
		let along = numerator / denominator
		let crossing = CGPoint(x: start.x + along * (end.x - start.x), y: start.y + along * (end.y - start.y))
		#expect(isClose(trapezoid.map(CGPoint(x: 0.5, y: 0.5)), crossing))
	}

	@Test("Three corners in a line leave no homography")
	func rejectsDegenerateQuads() {
		let flat = VideoPerspective(
			topLeft: CGPoint(x: 0, y: 0),
			topRight: CGPoint(x: 0.5, y: 0),
			bottomRight: CGPoint(x: 1, y: 0),
			bottomLeft: CGPoint(x: 0, y: 1)
		)
		#expect(flat.homography == nil)
	}

	@Test("A perspective survives a round trip")
	func roundTrips() throws {
		let data = try JSONEncoder().encode(trapezoid)
		#expect(try JSONDecoder().decode(VideoPerspective.self, from: data) == trapezoid)
	}
}

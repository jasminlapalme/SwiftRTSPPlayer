import CoreGraphics
import Testing
@testable import SwiftRTSPPlayer

@Suite("Perspective handles")
struct PerspectiveHandleLayoutTests {

	/// A 16:9 picture in a square view: letterboxed top and bottom.
	private let layout = PerspectiveHandleLayout(
		videoSize: CGSize(width: 1920, height: 1080),
		viewSize: CGSize(width: 400, height: 400)
	)

	@Test("The picture is fitted and centred, as the player draws it unframed")
	func fitsThePicture() {
		#expect(layout.pictureRect == CGRect(x: 0, y: 87.5, width: 400, height: 225))
	}

	@Test("The picture's own corners land on its rectangle's corners")
	func placesTheCorners() {
		#expect(layout.point(for: CGPoint(x: 0, y: 0)) == CGPoint(x: 0, y: 87.5))
		#expect(layout.point(for: CGPoint(x: 1, y: 1)) == CGPoint(x: 400, y: 312.5))
	}

	@Test("A dragged point goes back to the corner it shows")
	func roundTrips() {
		let corner = CGPoint(x: 0.25, y: 0.75)
		#expect(layout.corner(at: layout.point(for: corner)) == corner)
	}

	@Test("A handle dragged far off the picture stops at the editable range")
	func clampsToTheEditableRange() {
		let corner = layout.corner(at: CGPoint(x: -1000, y: 5000))
		#expect(corner == CGPoint(x: VideoPerspective.editableRange.lowerBound, y: VideoPerspective.editableRange.upperBound))
	}

	@Test("Each corner reads and writes its own point")
	func subscriptsTheCorners() {
		var perspective = VideoPerspective.identity
		perspective[.bottomRight] = CGPoint(x: 0.9, y: 0.8)
		#expect(perspective.bottomRight == CGPoint(x: 0.9, y: 0.8))
		#expect(perspective[.topLeft] == .zero)
		#expect(perspective[.topRight] == CGPoint(x: 1, y: 0))
		#expect(perspective[.bottomLeft] == CGPoint(x: 0, y: 1))
	}
}

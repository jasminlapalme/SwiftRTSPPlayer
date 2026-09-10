import CoreGraphics
import Testing
@testable import SwiftRTSPPlayer

@Suite("VideoMask")
struct VideoMaskTests {

	@Test("An untouched mask shows the whole picture")
	func identityShowsEverything() {
		#expect(VideoMask.identity.isIdentity)
		#expect(VideoMask.identity.visibleRect == CGRect(x: 0, y: 0, width: 1, height: 1))
	}

	@Test("Each side eats into the visible rect from its own edge")
	func sidesCropTheirOwnEdge() {
		let mask = VideoMask(left: 0.1, right: 0.2, top: 0.25, bottom: 0.05)
		#expect(!mask.isIdentity)
		let visible = mask.visibleRect
		#expect(abs(visible.minX - 0.1) < 1e-9)
		#expect(abs(visible.maxX - 0.8) < 1e-9)
		#expect(abs(visible.minY - 0.25) < 1e-9)
		#expect(abs(visible.maxY - 0.95) < 1e-9)
	}

	@Test("The anchor is not part of what counts as an open mask")
	func anchorDoesNotMakeAMask() {
		#expect(VideoMask(anchor: .view).isIdentity)
		#expect(!VideoMask(top: 0.1, anchor: .view).isIdentity)
		#expect(VideoMask.identity.anchor == .image)
	}

	@Test("The visible rect maps onto a destination of real coordinates")
	func visibleRectMapsOntoADestination() {
		let mask = VideoMask(left: 0.25, bottom: 0.5)
		let visible = mask.visibleRect(in: CGRect(x: 100, y: 40, width: 400, height: 200))
		#expect(visible == CGRect(x: 200, y: 40, width: 300, height: 100))
		#expect(VideoMask(left: 0.6, right: 0.6).visibleRect(in: .init(x: 0, y: 0, width: 8, height: 8)) == .zero)
	}

	@Test("Two sides that overlap leave nothing visible")
	func overlappingSidesAreEmpty() {
		#expect(VideoMask(left: 0.6, right: 0.6).visibleRect == .zero)
		#expect(VideoMask(top: 0.5, bottom: 0.5).visibleRect == .zero)
	}
}

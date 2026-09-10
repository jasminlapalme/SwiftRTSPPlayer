import CoreGraphics
import Testing
@testable import SwiftRTSPPlayer

@Suite("scissorRect")
struct ScissorRectTests {

	private let tile = CGRect(x: 0, y: 0, width: 2048, height: 1586)

	@Test("An image-anchored mask leaves the whole tile to the shader")
	func imageAnchorKeepsTheTile() {
		let mask = VideoMask(top: 0.25, anchor: .image)
		#expect(scissorRect(for: mask, in: tile) == tile)
		#expect(scissorRect(for: .identity, in: tile) == tile)
	}

	@Test("A view-anchored mask cuts the tile down")
	func viewAnchorCutsTheTile() {
		let visible = scissorRect(for: VideoMask(left: 0.5, anchor: .view), in: tile)
		#expect(visible == CGRect(x: 1024, y: 0, width: 1024, height: 1586))
	}

	@Test("A fraction that does not divide a pixel evenly stays inside the tile")
	func roundingStaysInsideTheTile() {
		// 0.20398667084356698 × 1586 puts the far edge at 1586.0000000000002,
		// which rounding outward took to 1587 — one row past the render pass.
		let visible = scissorRect(for: VideoMask(top: 0.20398667084356698, anchor: .view), in: tile)
		#expect(visible.maxY <= tile.maxY)
		#expect(visible.minY >= tile.minY)
		#expect(visible == CGRect(x: 0, y: 324, width: 2048, height: 1262))
	}

	@Test("A mask that closes an axis leaves nothing to draw through")
	func aClosedMaskIsEmpty() {
		#expect(scissorRect(for: VideoMask(top: 0.6, bottom: 0.6, anchor: .view), in: tile) == .zero)
		// Narrower than a pixel: still nothing, rather than a rect Metal rejects.
		let sliver = VideoMask(left: 0.4999, right: 0.5, anchor: .view)
		#expect(scissorRect(for: sliver, in: CGRect(x: 0, y: 0, width: 100, height: 100)) == .zero)
	}

	@Test("No side is left outside the tile, whatever the fraction")
	func everyFractionStaysInsideTheTile() {
		for step in 0...200 {
			let side = CGFloat(step) / 400
			for mask in [
				VideoMask(left: side, anchor: .view),
				VideoMask(right: side, anchor: .view),
				VideoMask(top: side, anchor: .view),
				VideoMask(bottom: side, anchor: .view),
				VideoMask(left: side, right: side, top: side, bottom: side, anchor: .view)
			] {
				let visible = scissorRect(for: mask, in: tile)
				#expect(tile.contains(visible) || visible.isEmpty, "\(side) escaped the tile: \(visible)")
			}
		}
	}
}

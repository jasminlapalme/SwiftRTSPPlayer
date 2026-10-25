import Foundation
import Testing
@testable import SwiftRTSPPlayer

@Suite("FisheyeCorrection")
struct FisheyeCorrectionTests {

	@Test("The identity neither bends nor zooms the picture")
	func identityLeavesThePictureAlone() {
		#expect(FisheyeCorrection.identity == FisheyeCorrection(k1v: 0, k2v: 0, k3v: 0, k4v: 0, expansion: 1))
	}

	@Test("A correction saved before the expansion existed decodes without one")
	func decodesWithoutExpansion() throws {
		let json = Data(#"{"k1v":-0.35,"k2v":-0.06,"k3v":0,"k4v":0}"#.utf8)
		let correction = try JSONDecoder().decode(FisheyeCorrection.self, from: json)
		#expect(correction == FisheyeCorrection(k1v: -0.35, k2v: -0.06))
	}

	@Test("The expansion survives a round trip")
	func roundTripsTheExpansion() throws {
		let correction = FisheyeCorrection(k1v: -0.35, k2v: -0.06, expansion: 1.5)
		let data = try JSONEncoder().encode(correction)
		#expect(try JSONDecoder().decode(FisheyeCorrection.self, from: data) == correction)
	}
}

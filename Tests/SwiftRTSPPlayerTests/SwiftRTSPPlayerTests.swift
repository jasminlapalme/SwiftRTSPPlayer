import Foundation
import Testing
@testable import SwiftRTSPPlayer

// MARK: - annexBNALURanges

@Suite("annexBNALURanges")
struct AnnexBNALURangesTests {

	@Test("Empty input yields no ranges")
	func emptyInput() {
		#expect(annexBNALURanges(in: Data()).isEmpty)
	}

	@Test("Input with no start codes yields no ranges")
	func noStartCodes() {
		let data = Data([0x42, 0x43, 0x44, 0x45])
		#expect(annexBNALURanges(in: data).isEmpty)
	}

	@Test("Single 4-byte start code with payload")
	func singleFourByteStartCode() {
		let data = Data([0, 0, 0, 1, 0x67, 0x42])
		let ranges = annexBNALURanges(in: data)
		#expect(ranges.count == 1)
		#expect(Data(data[ranges[0]]) == Data([0x67, 0x42]))
	}

	@Test("Single 3-byte start code with payload")
	func singleThreeByteStartCode() {
		let data = Data([0, 0, 1, 0x68, 0xCE])
		let ranges = annexBNALURanges(in: data)
		#expect(ranges.count == 1)
		#expect(Data(data[ranges[0]]) == Data([0x68, 0xCE]))
	}

	@Test("Mixed 3- and 4-byte start codes are both detected")
	func mixedStartCodes() {
		let data = Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 1, 0x68, 0xCE, 0x3C])
		let ranges = annexBNALURanges(in: data)
		#expect(ranges.count == 2)
		#expect(Data(data[ranges[0]]) == Data([0x67, 0x42]))
		#expect(Data(data[ranges[1]]) == Data([0x68, 0xCE, 0x3C]))
	}

	@Test("Consecutive start codes never produce empty ranges")
	func consecutiveStartCodesProduceNoEmptyRanges() {
		// Adjacent start codes are pathological input — two 4-byte start codes
		// back-to-back with nothing between them. The parser must not yield a
		// zero-length range, since downstream consumers index byte 0 to read
		// the NAL header.
		let data = Data([0, 0, 0, 1, 0, 0, 0, 1, 0x67, 0x42])
		let ranges = annexBNALURanges(in: data)
		for range in ranges {
			#expect(!range.isEmpty)
		}
	}

	@Test("Trailing start code with no payload is dropped")
	func trailingStartCodeNoPayload() {
		let data = Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1])
		let ranges = annexBNALURanges(in: data)
		#expect(ranges.count == 1)
		#expect(Data(data[ranges[0]]) == Data([0x67, 0x42]))
	}
}

// MARK: - annexBtoAVCC

@Suite("annexBtoAVCC")
struct AnnexBToAVCCTests {

	@Test("Empty input passes through unchanged")
	func emptyInput() {
		#expect(annexBtoAVCC(Data()) == Data())
	}

	@Test("Input without start codes is returned verbatim")
	func passthrough() {
		let data = Data([0x01, 0x02, 0x03])
		#expect(annexBtoAVCC(data) == data)
	}

	@Test("Single NALU is prefixed by big-endian 32-bit length")
	func singleNalu() {
		let nalu = Data([0x67, 0x42, 0x00, 0x1F])
		let data = Data([0, 0, 0, 1]) + nalu
		let avcc = annexBtoAVCC(data)
		// 4-byte length = 4 (the NALU body), big-endian
		#expect(avcc == Data([0, 0, 0, 4]) + nalu)
	}

	@Test("Multiple NALUs each carry their own length prefix")
	func multipleNalus() {
		let sps = Data([0x67, 0x42])
		let pps = Data([0x68, 0xCE, 0x3C])
		let data = Data([0, 0, 0, 1]) + sps + Data([0, 0, 1]) + pps
		let avcc = annexBtoAVCC(data)
		#expect(avcc == Data([0, 0, 0, 2]) + sps + Data([0, 0, 0, 3]) + pps)
	}
}

// MARK: - extractParameterSetsFromAVCC

@Suite("extractParameterSetsFromAVCC")
struct ExtractParameterSetsFromAVCCTests {

	@Test("Empty data returns nil")
	func emptyData() {
		#expect(extractParameterSetsFromAVCC(Data()) == nil)
	}

	@Test("Data shorter than the AVCC header returns nil")
	func tooShort() {
		// AVCC requires at least 7 bytes before any param set length.
		#expect(extractParameterSetsFromAVCC(Data([0x01, 0x42, 0x00, 0x1F, 0xFF, 0xE1])) == nil)
	}

	@Test("Wrong configurationVersion (≠ 1) returns nil")
	func wrongConfigurationVersion() {
		// First byte must be 0x01.
		var bytes: [UInt8] = [0x02]
		bytes += Array(repeating: 0xFF, count: 8)
		#expect(extractParameterSetsFromAVCC(Data(bytes)) == nil)
	}

	@Test("Truncated SPS length runs off the end → nil")
	func truncatedSpsLength() {
		// configurationVersion=1, 3 bytes profile/compat/level, lengthSizeMinusOne=3,
		// numOfSPS=1, then the 2-byte SPS size declares 100 bytes — but no payload.
		let header: [UInt8] = [0x01, 0x42, 0x00, 0x1F, 0xFF, 0xE1]
		let truncated: [UInt8] = [0x00, 0x64] // size=100 bytes claimed, none provided
		#expect(extractParameterSetsFromAVCC(Data(header + truncated)) == nil)
	}

	@Test("Zero-length SPS is rejected")
	func zeroLengthSpsIsRejected() {
		let header: [UInt8] = [0x01, 0x42, 0x00, 0x1F, 0xFF, 0xE1]
		let zeroSps: [UInt8] = [0x00, 0x00] // size=0
		#expect(extractParameterSetsFromAVCC(Data(header + zeroSps)) == nil)
	}

	@Test("Valid AVCC config returns SPS, PPS, and length size")
	func validAvccConfig() {
		let sps: [UInt8] = [0x67, 0x42, 0x00, 0x1F, 0xDA]
		let pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]
		var bytes: [UInt8] = [
			0x01,                         // configurationVersion
			0x42, 0x00, 0x1F,             // profile, compat, level
			0xFF,                         // 6 reserved bits + lengthSizeMinusOne (3 → 4-byte lengths)
			0xE1                          // 3 reserved bits + numOfSPS (1)
		]
		bytes += [UInt8(sps.count >> 8), UInt8(sps.count & 0xFF)] + sps
		bytes += [0x01]                  // numOfPPS (1)
		bytes += [UInt8(pps.count >> 8), UInt8(pps.count & 0xFF)] + pps

		guard let result = extractParameterSetsFromAVCC(Data(bytes)) else {
			Issue.record("expected non-nil result for valid AVCC bytes")
			return
		}
		#expect(result.sps == Data(sps))
		#expect(result.pps == Data(pps))
		#expect(result.nalUnitHeaderLength == 4)
	}

	@Test("PPS section truncated after SPS → nil")
	func truncatedAfterSps() {
		let sps: [UInt8] = [0x67, 0x42, 0x00, 0x1F, 0xDA]
		var bytes: [UInt8] = [0x01, 0x42, 0x00, 0x1F, 0xFF, 0xE1]
		bytes += [UInt8(sps.count >> 8), UInt8(sps.count & 0xFF)] + sps
		// Stop here — no PPS count or PPS payload.
		#expect(extractParameterSetsFromAVCC(Data(bytes)) == nil)
	}
}

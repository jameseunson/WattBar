import Testing
@testable import WattBarCore

@Suite("SMC decoding")
struct SMCCodecTests {
    @Test("flt decodes a little-endian IEEE float")
    func floatDecoding() {
        // 12.5 as little-endian Float bits: 0x41480000
        let bytes: [UInt8] = [0x00, 0x00, 0x48, 0x41]
        #expect(SMCCodec.decode(bytes: bytes, type: "flt ") == 12.5)
    }

    @Test("sp78 is a big-endian fixed-point value with 8 fraction bits")
    func signedFixedPointDecoding() {
        // 0x2A80 = 42.5
        #expect(SMCCodec.decode(bytes: [0x2A, 0x80], type: "sp78") == 42.5)
    }

    @Test("sp78 decodes negative temperatures")
    func negativeFixedPointDecoding() {
        // 0xFF80 = -0.5 in two's complement
        #expect(SMCCodec.decode(bytes: [0xFF, 0x80], type: "sp78") == -0.5)
        // 0xEC00 = -20.0
        #expect(SMCCodec.decode(bytes: [0xEC, 0x00], type: "sp78") == -20.0)
    }

    @Test("unsigned integers decode big-endian")
    func unsignedDecoding() {
        #expect(SMCCodec.decode(bytes: [0xFF], type: "ui8 ") == 255)
        #expect(SMCCodec.decode(bytes: [0x01, 0x00], type: "ui16") == 256)
        #expect(SMCCodec.decode(bytes: [0x00, 0x00, 0x01, 0x00], type: "ui32") == 256)
    }

    @Test("a buffer too short for its type decodes to nil rather than reading past the end")
    func shortBuffersAreRejected() {
        #expect(SMCCodec.decode(bytes: [0x00, 0x00, 0x48], type: "flt ") == nil)
        #expect(SMCCodec.decode(bytes: [0x2A], type: "sp78") == nil)
        #expect(SMCCodec.decode(bytes: [], type: "ui8 ") == nil)
        #expect(SMCCodec.decode(bytes: [0x01], type: "ui16") == nil)
        #expect(SMCCodec.decode(bytes: [0x01, 0x02, 0x03], type: "ui32") == nil)
    }

    @Test("an unknown type decodes to nil")
    func unknownTypeIsRejected() {
        #expect(SMCCodec.decode(bytes: [0, 0, 0, 0], type: "ch8*") == nil)
    }

    @Test("four-character codes round-trip")
    func fourCCRoundTrip() {
        let packed = try! #require(SMCCodec.fourCC("PSTR"))
        #expect(packed == 0x5053_5452)
        #expect(SMCCodec.fourCCString(packed) == "PSTR")
    }

    @Test("only four ASCII characters make a key")
    func fourCCRejectsBadKeys() {
        #expect(SMCCodec.fourCC("PST") == nil)
        #expect(SMCCodec.fourCC("PSTRX") == nil)
        #expect(SMCCodec.fourCC("PST\u{00E9}") == nil)
    }
}

@Suite("IOReport unit conversion")
struct IOReportUnitsTests {
    @Test("each energy unit scales to joules")
    func unitsScale() {
        #expect(IOReportUnits.joules(value: 1_000_000_000, unit: "nJ") == 1)
        #expect(IOReportUnits.joules(value: 1_000_000, unit: "uJ") == 1)
        #expect(IOReportUnits.joules(value: 1_000_000, unit: "µJ") == 1)
        #expect(IOReportUnits.joules(value: 1_000, unit: "mJ") == 1)
        #expect(IOReportUnits.joules(value: 7, unit: "J") == 7)
    }

    @Test("unit labels come back padded, so they are trimmed before matching")
    func paddedUnitsAreTrimmed() {
        #expect(IOReportUnits.joules(value: 1_000, unit: " mJ ") == 1)
        #expect(IOReportUnits.joules(value: 1_000_000_000, unit: "nJ\t") == 1)
    }

    @Test("an unknown unit converts to nil rather than a wrong number")
    func unknownUnitIsRejected() {
        #expect(IOReportUnits.joules(value: 1, unit: "kJ") == nil)
        #expect(IOReportUnits.joules(value: 1, unit: "") == nil)
    }
}

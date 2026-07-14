import Foundation

/// Decoding for the SMC's wire format: four-character key/type codes, and the
/// handful of numeric encodings its sensor keys use. Pure byte work, so it is
/// separable from the IOKit connection that fetches those bytes.
public enum SMCCodec {
    /// Decodes a sensor payload as a scalar. Returns nil for a type this
    /// doesn't know, or a buffer too short for the type it claims to be.
    public static func decode(bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "flt " where bytes.count >= 4:
            let raw = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return Double(Float(bitPattern: UInt32(littleEndian: raw)))
        case "sp78" where bytes.count >= 2:
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256.0
        case "ui8 " where bytes.count >= 1:
            return Double(bytes[0])
        case "ui16" where bytes.count >= 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32" where bytes.count >= 4:
            return Double(bytes[0...3].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        default:
            return nil
        }
    }

    /// Packs a four-character key (e.g. "PSTR") into the UInt32 the SMC wants.
    public static func fourCC(_ key: String) -> UInt32? {
        let scalars = Array(key.unicodeScalars)
        guard scalars.count == 4, scalars.allSatisfy({ $0.isASCII }) else { return nil }
        return scalars.reduce(UInt32(0)) { $0 << 8 | UInt32($1.value) }
    }

    /// Unpacks a UInt32 key or type code back into its four characters.
    public static func fourCCString(_ value: UInt32) -> String {
        let characters = stride(from: 24, through: 0, by: -8).map {
            Character(UnicodeScalar(UInt8((value >> UInt32($0)) & 0xFF)))
        }
        return String(characters)
    }
}

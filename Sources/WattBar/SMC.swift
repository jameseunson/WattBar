import Foundation
import IOKit

/// Minimal client for the Apple System Management Controller (SMC).
///
/// Power sensor keys (e.g. "PSTR", System Total Power) are readable without
/// elevated privileges, unlike `powermetrics` which requires root.
final class SMC {
    typealias SMCBytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    private struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    /// Mirrors the kernel's SMCParamStruct. The explicit `padding` field keeps
    /// Swift's layout identical to the C struct's 80-byte layout.
    private struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes = (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    private enum Command: UInt8 {
        case readKey = 5
        case getKeyFromIndex = 8
        case getKeyInfo = 9
    }

    private static let handleYPCEventSelector: UInt32 = 2

    private let connection: io_connect_t

    init?() {
        guard MemoryLayout<SMCParamStruct>.stride == 80 else {
            assertionFailure("SMCParamStruct layout mismatch")
            return nil
        }
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess,
              connection != IO_OBJECT_NULL
        else { return nil }
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    /// Reads a sensor key and decodes it as a power/scalar value.
    func readValue(key: String) -> Double? {
        guard let keyCode = Self.fourCC(key) else { return nil }

        var infoRequest = SMCParamStruct()
        infoRequest.key = keyCode
        infoRequest.data8 = Command.getKeyInfo.rawValue
        guard let info = call(&infoRequest) else { return nil }

        var readRequest = SMCParamStruct()
        readRequest.key = keyCode
        readRequest.keyInfo.dataSize = info.keyInfo.dataSize
        readRequest.data8 = Command.readKey.rawValue
        guard let response = call(&readRequest) else { return nil }

        let size = Int(info.keyInfo.dataSize)
        let bytes = withUnsafeBytes(of: response.bytes) { Array($0.prefix(size)) }
        let type = Self.fourCCString(info.keyInfo.dataType)
        return Self.decode(bytes: bytes, type: type)
    }

    /// All keys the SMC exposes on this machine, via the key-at-index command.
    func allKeys() -> [String] {
        guard let count = readValue(key: "#KEY").map(Int.init) else { return [] }
        return (0..<count).compactMap { index in
            var input = SMCParamStruct()
            input.data8 = Command.getKeyFromIndex.rawValue
            input.data32 = UInt32(index)
            guard let output = call(&input) else { return nil }
            return Self.fourCCString(output.key)
        }
    }

    /// The four-character data type of a key (e.g. "flt ", "ui16").
    func typeOf(key: String) -> String? {
        guard let keyCode = Self.fourCC(key) else { return nil }
        var input = SMCParamStruct()
        input.key = keyCode
        input.data8 = Command.getKeyInfo.rawValue
        guard let info = call(&input) else { return nil }
        return Self.fourCCString(info.keyInfo.dataType)
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let status = IOConnectCallStructMethod(
            connection,
            Self.handleYPCEventSelector,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        guard status == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private static func decode(bytes: [UInt8], type: String) -> Double? {
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

    private static func fourCC(_ key: String) -> UInt32? {
        let scalars = Array(key.unicodeScalars)
        guard scalars.count == 4, scalars.allSatisfy({ $0.isASCII }) else { return nil }
        return scalars.reduce(UInt32(0)) { $0 << 8 | UInt32($1.value) }
    }

    private static func fourCCString(_ value: UInt32) -> String {
        let characters = stride(from: 24, through: 0, by: -8).map {
            Character(UnicodeScalar(UInt8((value >> UInt32($0)) & 0xFF)))
        }
        return String(characters)
    }
}

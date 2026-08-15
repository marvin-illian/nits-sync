import Foundation
import NitsCtrlHardware

enum HardwareProbe {
    struct DisplayResult: Codable {
        let name: String
        let manufacturer: String
        let vendorID: UInt32
        let productID: UInt32
        let serialNumber: UInt32?
        let alphanumericSerial: String?
        let stableIdentity: String
        let currentRawBrightness: UInt16?
        let maximumRawBrightness: UInt16?
        let edidMaximumNitsEstimate: Double?
        let error: String?
    }

    struct Result: Codable {
        let builtInNits: Double?
        let builtInName: String?
        let externalDisplays: [DisplayResult]
    }

    static func run() -> Int32 {
        let nitsReader = BuiltInNitsReader()
        let ddc = DDCTransport()
        do {
            let displays = try ddc.discover()
            let results = displays.map { display -> DisplayResult in
                do {
                    let raw = try ddc.readBrightness(display)
                    return DisplayResult(
                        name: display.name,
                        manufacturer: display.manufacturerID,
                        vendorID: display.vendorID,
                        productID: display.productID,
                        serialNumber: display.serialNumber,
                        alphanumericSerial: display.alphanumericSerial,
                        stableIdentity: display.identity.stableKey,
                        currentRawBrightness: raw.current,
                        maximumRawBrightness: raw.maximum,
                        edidMaximumNitsEstimate: EDIDLuminance.maximumNits(from: display.edidData),
                        error: nil
                    )
                } catch {
                    return DisplayResult(
                        name: display.name,
                        manufacturer: display.manufacturerID,
                        vendorID: display.vendorID,
                        productID: display.productID,
                        serialNumber: display.serialNumber,
                        alphanumericSerial: display.alphanumericSerial,
                        stableIdentity: display.identity.stableKey,
                        currentRawBrightness: nil,
                        maximumRawBrightness: nil,
                        edidMaximumNitsEstimate: EDIDLuminance.maximumNits(from: display.edidData),
                        error: error.localizedDescription
                    )
                }
            }
            let result = Result(
                builtInNits: nitsReader.currentNits(),
                builtInName: nitsReader.builtInDisplayName,
                externalDisplays: results
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(result))
            FileHandle.standardOutput.write(Data("\n".utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("Nits Sync probe failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}

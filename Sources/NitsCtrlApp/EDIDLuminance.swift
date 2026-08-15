import Foundation

/// Reads the optional CTA-861 desired-content maximum luminance hint.
/// It is useful only as a starting estimate; it is not a live measurement.
enum EDIDLuminance {
    static func maximumNits(from edid: Data) -> Double? {
        let bytes = [UInt8](edid)
        guard bytes.count >= 256, bytes.count.isMultiple(of: 128) else {
            return nil
        }

        let extensionCount = min(Int(bytes[126]), bytes.count / 128 - 1)
        guard extensionCount > 0 else { return nil }
        for extensionIndex in 1...extensionCount {
            let start = extensionIndex * 128
            guard bytes[start] == 0x02 else { continue }
            let dataBlockEnd = bytes[start + 2] == 0
                ? start + 127
                : min(start + Int(bytes[start + 2]), start + 127)
            var cursor = start + 4

            while cursor < dataBlockEnd {
                let header = bytes[cursor]
                let tag = header >> 5
                let length = Int(header & 0x1f)
                let next = cursor + 1 + length
                guard length > 0, next <= dataBlockEnd else { break }

                // Extended data block tag 0x06 is HDR static metadata.
                if tag == 0x07, bytes[cursor + 1] == 0x06, length >= 4 {
                    let code = bytes[cursor + 4]
                    guard code > 0 else { return nil }
                    return 50.0 * pow(2.0, Double(code) / 32.0)
                }
                cursor = next
            }
        }
        return nil
    }
}

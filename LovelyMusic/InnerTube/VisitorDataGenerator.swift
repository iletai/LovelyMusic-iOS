import Foundation

/// Generates fresh YouTube visitorData tokens using protobuf encoding.
///
/// visitorData is a URL-safe base64 protobuf with:
///   - field 1 (length-delimited string): 11-character random ID [A-Za-z0-9_-]
///   - field 5 (varint): Unix timestamp in seconds
///
/// YouTube accepts any well-formed protobuf token with a recent timestamp.
/// Generated tokens are anonymous (no personalization) but guarantee fresh
/// content responses instead of stale cached data.
struct VisitorDataGenerator {
    private static let idCharset = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
    )

    /// Generates a fresh visitorData token with the current timestamp.
    static func generate() -> String {
        let id = generateRandomID(length: 11)
        let timestamp = UInt64(Date().timeIntervalSince1970)
        let proto = encodeProtobuf(id: id, timestamp: timestamp)
        return proto.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func generateRandomID(length: Int) -> String {
        String((0..<length).map { _ in idCharset.randomElement()! })
    }

    private static func encodeProtobuf(id: String, timestamp: UInt64) -> Data {
        var data = Data()
        // Field 1, wire type 2 (length-delimited) = (1 << 3) | 2 = 0x0A
        let idBytes = Data(id.utf8)
        data.append(0x0A)
        data.append(contentsOf: encodeVarint(UInt64(idBytes.count)))
        data.append(idBytes)
        // Field 5, wire type 0 (varint) = (5 << 3) | 0 = 0x28
        data.append(0x28)
        data.append(contentsOf: encodeVarint(timestamp))
        return data
    }

    private static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var result: [UInt8] = []
        var v = value
        while v > 0x7F {
            result.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        result.append(UInt8(v & 0x7F))
        return result
    }
}

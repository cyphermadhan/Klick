import Foundation

/// Hand-rolled protobuf wire-format primitives.
///
/// We only need a tiny subset of protobuf to talk to Meshtastic: varints,
/// length-delimited bytes fields, and fixed32 fields. Pulling in
/// swift-protobuf (plus regenerating hundreds of Meshtastic message types)
/// is overkill for the five messages we actually serialize.
///
/// Proto3 wire format crib:
///
///   Every field is prefixed with a **tag** = `(field_number << 3) | wire_type`.
///   Wire types we use:
///     - 0 = Varint      (bool, int32, uint32, enum)
///     - 2 = Length-delimited (bytes, string, embedded message)
///     - 5 = 32-bit fixed  (fixed32, sfixed32, float)
///
/// Reference: https://protobuf.dev/programming-guides/encoding/
enum ProtobufWire {
    /// Protobuf wire types we care about.
    enum WireType: UInt8 {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    /// Build a `tag` byte varint for `(field, wire)`. Used by every
    /// encoder before it writes the value.
    static func tag(field: UInt32, wire: WireType) -> [UInt8] {
        var bytes: [UInt8] = []
        encodeVarint(UInt64(field) << 3 | UInt64(wire.rawValue), into: &bytes)
        return bytes
    }

    // MARK: - Encode

    /// Append a varint representation of `value` to `buffer`.
    static func encodeVarint(_ value: UInt64, into buffer: inout [UInt8]) {
        var v = value
        while v >= 0x80 {
            buffer.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        buffer.append(UInt8(v & 0x7F))
    }

    /// Append a little-endian 32-bit fixed value.
    static func encodeFixed32(_ value: UInt32, into buffer: inout [UInt8]) {
        buffer.append(UInt8(value & 0xFF))
        buffer.append(UInt8((value >> 8) & 0xFF))
        buffer.append(UInt8((value >> 16) & 0xFF))
        buffer.append(UInt8((value >> 24) & 0xFF))
    }

    /// Append `tag + varint`. Use for `uint32`, `uint64`, `bool`, enums.
    static func encodeVarintField(_ field: UInt32, _ value: UInt64, into buffer: inout [UInt8]) {
        buffer.append(contentsOf: tag(field: field, wire: .varint))
        encodeVarint(value, into: &buffer)
    }

    /// Append `tag + length + bytes`. Use for `bytes`, `string`, or any
    /// embedded message (its pre-encoded blob).
    static func encodeBytesField(_ field: UInt32, _ bytes: Data, into buffer: inout [UInt8]) {
        buffer.append(contentsOf: tag(field: field, wire: .lengthDelimited))
        encodeVarint(UInt64(bytes.count), into: &buffer)
        buffer.append(contentsOf: bytes)
    }

    /// Append `tag + fixed32`. Use for `fixed32`, `sfixed32`, `float`.
    static func encodeFixed32Field(_ field: UInt32, _ value: UInt32, into buffer: inout [UInt8]) {
        buffer.append(contentsOf: tag(field: field, wire: .fixed32))
        encodeFixed32(value, into: &buffer)
    }

    // MARK: - Decode

    /// Errors produced when a buffer can't be parsed as protobuf.
    enum DecodeError: Error, Equatable {
        case truncated
        case unknownWireType(UInt8)
        case varintTooLong
    }

    /// Cursor over a protobuf buffer. Callers read fields in a loop; each
    /// call to `nextField()` returns the next tag and advances past its
    /// value, skipping fields you don't care about.
    struct Reader {
        let data: Data
        private(set) var offset: Int

        init(_ data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        var isAtEnd: Bool { offset >= data.endIndex }

        /// Read a varint starting at `offset`. Advances `offset` past it.
        mutating func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            var bytesRead = 0
            while true {
                guard offset < data.endIndex else { throw DecodeError.truncated }
                let byte = data[offset]
                offset += 1
                bytesRead += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
                // A varint is at most 10 bytes (70 bits for a 64-bit value).
                if bytesRead > 10 { throw DecodeError.varintTooLong }
            }
            return result
        }

        /// Read a 4-byte little-endian fixed32. Advances `offset`.
        mutating func readFixed32() throws -> UInt32 {
            guard offset + 4 <= data.endIndex else { throw DecodeError.truncated }
            let b0 = UInt32(data[offset])
            let b1 = UInt32(data[offset + 1]) << 8
            let b2 = UInt32(data[offset + 2]) << 16
            let b3 = UInt32(data[offset + 3]) << 24
            offset += 4
            return b0 | b1 | b2 | b3
        }

        /// Read a length-delimited block. Returns the raw bytes (sliced
        /// from the underlying buffer; no copy). Advances `offset`.
        mutating func readLengthDelimited() throws -> Data {
            let length = try readVarint()
            let end = offset + Int(length)
            guard end <= data.endIndex else { throw DecodeError.truncated }
            let slice = data.subdata(in: offset..<end)
            offset = end
            return slice
        }

        /// Skip an unknown field of the given wire type — what you do
        /// when `nextField()` returns a field number you don't recognize.
        mutating func skip(wire: WireType) throws {
            switch wire {
            case .varint:
                _ = try readVarint()
            case .lengthDelimited:
                _ = try readLengthDelimited()
            case .fixed32:
                guard offset + 4 <= data.endIndex else { throw DecodeError.truncated }
                offset += 4
            case .fixed64:
                guard offset + 8 <= data.endIndex else { throw DecodeError.truncated }
                offset += 8
            }
        }

        /// Read the next tag. Returns `nil` at end-of-buffer.
        mutating func nextField() throws -> (field: UInt32, wire: WireType)? {
            guard !isAtEnd else { return nil }
            let tag = try readVarint()
            let fieldNum = UInt32(tag >> 3)
            let wireRaw = UInt8(tag & 0x07)
            guard let wire = WireType(rawValue: wireRaw) else {
                throw DecodeError.unknownWireType(wireRaw)
            }
            return (fieldNum, wire)
        }
    }
}

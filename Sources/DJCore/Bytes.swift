import Foundation

struct ByteReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard offset + n <= bytes.count else { throw BeatDataError.corrupt }
        defer { offset += n }
        return bytes[offset..<offset + n]
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }

    mutating func u64be() throws -> UInt64 { try take(8).reduce(0) { $0 << 8 | UInt64($1) } }
    mutating func u64le() throws -> UInt64 { try take(8).reversed().reduce(0) { $0 << 8 | UInt64($1) } }
    mutating func u32le() throws -> UInt32 { try take(4).reversed().reduce(0) { $0 << 8 | UInt32($1) } }

    mutating func f64be() throws -> Double { Double(bitPattern: try u64be()) }
    mutating func f64le() throws -> Double { Double(bitPattern: try u64le()) }
    mutating func i64be() throws -> Int64 { Int64(bitPattern: try u64be()) }
    mutating func i64le() throws -> Int64 { Int64(bitPattern: try u64le()) }
    mutating func i32le() throws -> Int32 { Int32(bitPattern: try u32le()) }

    func rest() -> [UInt8] { Array(bytes[offset...]) }
}

struct ByteWriter {
    var data: [UInt8] = []

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func bytes(_ v: [UInt8]) { data += v }
    mutating func u64be(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { data.append(UInt8(v >> UInt64(s) & 0xff)) } }
    mutating func u64le(_ v: UInt64) { for s in stride(from: 0, through: 56, by: 8) { data.append(UInt8(v >> UInt64(s) & 0xff)) } }
    mutating func u32le(_ v: UInt32) { for s in stride(from: 0, through: 24, by: 8) { data.append(UInt8(v >> UInt32(s) & 0xff)) } }
    mutating func u32be(_ v: UInt32) { for s in stride(from: 24, through: 0, by: -8) { data.append(UInt8(v >> UInt32(s) & 0xff)) } }
    mutating func f64be(_ v: Double) { u64be(v.bitPattern) }
    mutating func f64le(_ v: Double) { u64le(v.bitPattern) }
    mutating func i64be(_ v: Int64) { u64be(UInt64(bitPattern: v)) }
    mutating func i64le(_ v: Int64) { u64le(UInt64(bitPattern: v)) }
    mutating func i32le(_ v: Int32) { u32le(UInt32(bitPattern: v)) }
}

extension Array where Element == UInt8 {
    func u32be(at o: Int) -> UInt32 { UInt32(self[o]) << 24 | UInt32(self[o + 1]) << 16 | UInt32(self[o + 2]) << 8 | UInt32(self[o + 3]) }
    func u32le(at o: Int) -> UInt32 { UInt32(self[o + 3]) << 24 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 1]) << 8 | UInt32(self[o]) }
    func syncsafe(at o: Int) -> Int { Int(self[o] & 0x7f) << 21 | Int(self[o + 1] & 0x7f) << 14 | Int(self[o + 2] & 0x7f) << 7 | Int(self[o + 3] & 0x7f) }
    func ascii(_ range: Range<Int>) -> String { String(decoding: self[range], as: UTF8.self) }
}

func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)] }
func syncsafe32(_ v: Int) -> [UInt8] { [UInt8(v >> 21 & 0x7f), UInt8(v >> 14 & 0x7f), UInt8(v >> 7 & 0x7f), UInt8(v & 0x7f)] }

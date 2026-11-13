//
//  SyncJSON.swift
//  Whisperer
//
//  A small Codable JSON value, so a Core Data row (as produced by `HistoryArchive.encodeRow`) can travel inside a
//  typed change batch without a second row format.
//

import Foundation

nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// From the `[String: Any]` rows of `HistoryArchive.encodeRow` (NSNumber / String values).
    static func fromRow(_ row: [String: Any]) throws -> JSONValue {
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Back to the dictionary `HistoryArchive.decodeRow` reads.
    func toRow() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudCryptoError.malformedObject
        }
        return row
    }

    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }

    /// Canonical bytes (sorted keys) — what content hashes are computed over.
    func canonicalData() -> Data {
        var out = Data()
        write(into: &out)
        return out
    }

    private func write(into out: inout Data) {
        switch self {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .number(let n): out.append(contentsOf: Array("\(n)".utf8))
        case .string(let s):
            out.append(contentsOf: Array((String(data: (try? JSONEncoder().encode(s)) ?? Data(), encoding: .utf8) ?? "\"\"").utf8))
        case .array(let a):
            out.append(0x5B)
            for (i, v) in a.enumerated() { if i > 0 { out.append(0x2C) }; v.write(into: &out) }
            out.append(0x5D)
        case .object(let o):
            out.append(0x7B)
            for (i, k) in o.keys.sorted().enumerated() {
                if i > 0 { out.append(0x2C) }
                JSONValue.string(k).write(into: &out)
                out.append(0x3A)
                o[k]!.write(into: &out)
            }
            out.append(0x7D)
        }
    }
}

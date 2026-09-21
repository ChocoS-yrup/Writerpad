import Foundation

public enum WindowsReaderError: String, Error { case json, size, shape, pin, binding, hash, reference, contract, body, structure, evidence, creation, authority, unverified, file }

func wrNeed(_ value: @autoclosure () throws -> Bool, _ error: WindowsReaderError) throws {
    if try !value() { throw error }
}

/// Wire numbers retain lexical form. Bool, 1, 1.0 and 1e0 never share a representation.
indirect enum WindowsJSON: Equatable, Sendable {
    case object([String: WindowsJSON]), array([WindowsJSON]), string(String), number(String), bool(Bool), null
    func object() throws -> [String: WindowsJSON] { guard case let .object(v) = self else { throw WindowsReaderError.shape }; return v }
    func array() throws -> [WindowsJSON] { guard case let .array(v) = self else { throw WindowsReaderError.shape }; return v }
    func string() throws -> String { guard case let .string(v) = self else { throw WindowsReaderError.shape }; return v }
    func int(_ minimum: Int = 0) throws -> Int {
        guard case let .number(v) = self, v.range(of:"^-?(0|[1-9][0-9]*)$",options:.regularExpression) != nil,
              let n = Int(v), n >= minimum, n <= 9_007_199_254_740_991 else { throw WindowsReaderError.contract }; return n
    }
    func get(_ key: String) throws -> WindowsJSON { guard let v = try object()[key] else { throw WindowsReaderError.shape }; return v }
    func str(_ key: String) throws -> String { try get(key).string() }
    func list(_ key: String) throws -> [WindowsJSON] { try get(key).array() }
    func keys(_ names: [String]) throws { try wrNeed(Set(object().keys) == Set(names), .shape) }
    func equalBytes(_ other: WindowsJSON) -> Bool { encoded() == other.encoded() }
    func encoded(lf: Bool = false) -> Data {
        func quoted(_ text: String) -> String {
            var out = "\""
            for u in text.unicodeScalars {
                switch u.value {
                case 34: out += "\\\""
                case 92: out += "\\\\"
                case 8: out += "\\b"
                case 9: out += "\\t"
                case 10: out += "\\n"
                case 12: out += "\\f"
                case 13: out += "\\r"
                case 0...31: out += String(format:"\\u%04x",u.value)
                default: out.unicodeScalars.append(u)
                }
            }
            return out + "\""
        }
        func emit(_ v: WindowsJSON) -> String {
            switch v {
            case .null: return "null"
            case let .bool(b): return b ? "true" : "false"
            case let .number(n): return n
            case let .string(s): return quoted(s)
            case let .array(a): return "[" + a.map(emit).joined(separator:",") + "]"
            case let .object(o): return "{" + o.keys.sorted().map { quoted($0)+":"+emit(o[$0]!) }.joined(separator:",") + "}"
            }
        }
        return Data((emit(self) + (lf ? "\n" : "")).utf8)
    }
    func pointer(_ pointer: String) throws -> WindowsJSON {
        if pointer.isEmpty { return self }
        try wrNeed(pointer.hasPrefix("/"), .reference)
        var value = self
        for part in pointer.dropFirst().components(separatedBy:"/") {
            try wrNeed(part.range(of:"~(?![01])",options:.regularExpression) == nil, .reference)
            let key = part.replacingOccurrences(of:"~1",with:"/").replacingOccurrences(of:"~0",with:"~")
            switch value {
            case let .object(o): guard let next = o[key] else { throw WindowsReaderError.reference }; value = next
            case let .array(a):
                guard key.range(of:"^(0|[1-9][0-9]*)$",options:.regularExpression) != nil, let n = Int(key), n < a.count else { throw WindowsReaderError.reference }; value = a[n]
            default: throw WindowsReaderError.reference
            }
        }
        return value
    }
    static func decode(_ data: Data, limit: Int = 4*1024*1024) throws -> WindowsJSON {
        try wrNeed(data.count <= limit && String(data:data,encoding:.utf8) != nil, .size)
        var parser = WindowsJSONParser(bytes:Array(data)); return try parser.parse()
    }
}

private struct WindowsJSONParser {
    let bytes: [UInt8]
    var i = 0
    mutating func space() { while i < bytes.count && [9,10,13,32].contains(bytes[i]) { i += 1 } }
    mutating func parse() throws -> WindowsJSON { let v = try value(0); space(); try wrNeed(i == bytes.count,.json); return v }
    mutating func consume(_ byte: UInt8) throws { try wrNeed(i < bytes.count && bytes[i] == byte,.json); i += 1 }
    mutating func string() throws -> String {
        let start = i; try consume(34)
        while i < bytes.count {
            let b = bytes[i]; i += 1
            if b == 34 {
                do { return try JSONDecoder().decode(String.self,from:Data(bytes[start..<i])) }
                catch { throw WindowsReaderError.json }
            }
            try wrNeed(b >= 32,.json)
            if b == 92 { try wrNeed(i < bytes.count,.json); i += 1 }
        }
        throw WindowsReaderError.json
    }
    mutating func value(_ depth: Int) throws -> WindowsJSON {
        space(); try wrNeed(depth <= 64 && i < bytes.count,.json)
        switch bytes[i] {
        case 34: return .string(try string())
        case 123:
            i += 1; space(); var object: [String:WindowsJSON] = [:]
            if i < bytes.count && bytes[i] == 125 { i += 1; return .object(object) }
            while true {
                space(); let k = try string(); try wrNeed(object[k] == nil,.json)
                space(); try consume(58); object[k] = try value(depth+1); space()
                if i < bytes.count && bytes[i] == 125 { i += 1; return .object(object) }
                try consume(44)
            }
        case 91:
            i += 1; space(); var array: [WindowsJSON] = []
            if i < bytes.count && bytes[i] == 93 { i += 1; return .array(array) }
            while true {
                array.append(try value(depth+1)); space()
                if i < bytes.count && bytes[i] == 93 { i += 1; return .array(array) }
                try consume(44)
            }
        case 116,102,110:
            let b = bytes[i], token = b == 116 ? "true" : b == 102 ? "false" : "null"
            for x in token.utf8 { try consume(x) }
            return b == 110 ? .null : .bool(b == 116)
        default:
            let start = i
            while i < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[i]) { i += 1 }
            let token = String(decoding:bytes[start..<i],as:UTF8.self)
            try wrNeed(token.range(of:"^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$",options:.regularExpression) != nil,.json)
            try wrNeed(Double(token)?.isFinite == true,.json)
            return .number(token)
        }
    }
}

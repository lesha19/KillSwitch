import Foundation

/// The geodata the app ships (Helper/geosite.dat, Helper/geoip.metadb, the same files the core
/// reads), for «Проверить адрес»: is a domain in a GEOSITE category, is an IPv4 address in a GEOIP
/// country. Read once, lazily; nil answers mean «cannot tell».
final class GeoData: @unchecked Sendable {
    private let lock = NSLock()
    private let siteURL: URL?
    private let ipURL: URL?
    private var siteData: Data?
    private var sites: [String: [GeoSite.Domain]] = [:]
    private var ipDB: MMDB?
    private var ipLoaded = false

    init(site: URL?, ip: URL?) {
        siteURL = site
        ipURL = ip
    }

    /// The files inside the app bundle (Contents/Resources/Helper).
    static let bundled = GeoData(site: Bundle.main.url(forResource: "geosite", withExtension: "dat", subdirectory: "Helper"),
                                 ip: Bundle.main.url(forResource: "geoip", withExtension: "metadb", subdirectory: "Helper"))

    /// GEOSITE,<category>: nil when there is no geosite.dat or the category has attributes (`@cn`).
    func site(_ category: String, contains host: String) -> Bool? {
        guard !category.contains("@") else { return nil }
        let key = category.uppercased()
        return lock.withLock { () -> Bool? in
            if siteData == nil, let siteURL { siteData = try? Data(contentsOf: siteURL, options: .mappedIfSafe) }
            guard let data = siteData else { return nil }
            if sites[key] == nil { sites[key] = GeoSite.domains(of: key, in: data) ?? [] }
            return sites[key]!.contains { $0.matches(host) }
        }
    }

    /// GEOIP,<country> for an IPv4 address: nil when there is no geoip.metadb or it cannot be read.
    func ip(_ address: String, inCountry country: String) -> Bool? {
        lock.withLock { () -> Bool? in
            if !ipLoaded {
                ipLoaded = true
                ipDB = ipURL.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }.flatMap(MMDB.init)
            }
            guard let codes = ipDB?.countries(of: address) else { return nil }
            return codes.contains { $0.caseInsensitiveCompare(country) == .orderedSame }
        }
    }
}

/// v2ray's geosite.dat: `GeoSiteList { repeated GeoSite entry = 1 }`, `GeoSite { string
/// country_code = 1; repeated Domain domain = 2 }`, `Domain { Type type = 1; string value = 2 }`.
enum GeoSite {
    struct Domain: Equatable {
        /// 0 keyword, 1 regex, 2 domain and its subdomains, 3 the exact name
        var type: Int
        var value: String

        func matches(_ host: String) -> Bool {
            let host = host.lowercased(), value = value.lowercased()
            switch type {
            case 0: return host.contains(value)
            case 1: return host.range(of: value, options: .regularExpression) != nil
            case 2: return host == value || host.hasSuffix("." + value)
            case 3: return host == value
            default: return false
            }
        }
    }

    /// The domains of one category (upper-case code), nil if the file cannot be read.
    static func domains(of category: String, in data: Data) -> [Domain]? {
        var reader = ProtoReader(data)
        while !reader.atEnd {
            guard let (field, wire) = reader.key() else { return nil }
            guard field == 1, wire == 2, let entry = reader.bytes() else {
                guard reader.skip(wire) else { return nil }
                continue
            }
            var site = ProtoReader(entry)
            var code: String?
            var domains: [Domain] = []
            while !site.atEnd {
                guard let (f, w) = site.key() else { return nil }
                if f == 1, w == 2, let text = site.bytes() {
                    code = String(decoding: text, as: UTF8.self).uppercased()
                    if code != category { break }
                } else if f == 2, w == 2, let item = site.bytes() {
                    var d = ProtoReader(item)
                    var domain = Domain(type: 0, value: "")
                    while !d.atEnd {
                        guard let (df, dw) = d.key() else { break }
                        if df == 1, dw == 0, let v = d.varint() { domain.type = Int(v) }
                        else if df == 2, dw == 2, let v = d.bytes() { domain.value = String(decoding: v, as: UTF8.self) }
                        else if !d.skip(dw) { break }
                    }
                    domains.append(domain)
                } else if !site.skip(w) {
                    return nil
                }
            }
            if code == category { return domains }
        }
        return []
    }
}

/// Protocol buffers, just what geosite.dat needs.
struct ProtoReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var atEnd: Bool { offset >= data.endIndex }

    mutating func varint() -> UInt64? {
        var result: UInt64 = 0, shift: UInt64 = 0
        while offset < data.endIndex, shift < 64 {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    mutating func key() -> (Int, Int)? {
        guard let k = varint() else { return nil }
        return (Int(k >> 3), Int(k & 7))
    }

    mutating func bytes() -> Data? {
        guard let n = varint(), n <= UInt64(data.endIndex - offset) else { return nil }
        let slice = data[offset..<offset + Int(n)]
        offset += Int(n)
        return slice
    }

    mutating func skip(_ wire: Int) -> Bool {
        switch wire {
        case 0: return varint() != nil
        case 1: offset += 8
        case 2: return bytes() != nil
        case 5: offset += 4
        default: return false
        }
        return offset <= data.endIndex
    }
}

/// A MaxMind DB (MetaCubeX's geoip.metadb, `Meta-geoip0`): the country codes of an IPv4 address.
struct MMDB {
    private let data: Data
    private let nodeCount: Int
    private let recordSize: Int
    private let ipVersion: Int
    private let treeSize: Int

    init?(_ data: Data) {
        let marker = Data([0xab, 0xcd, 0xef]) + Data("MaxMind.com".utf8)
        guard let range = data.range(of: marker, options: .backwards) else { return nil }
        self.data = data
        var at = range.upperBound
        guard case .map(let meta)? = Self.decode(data, &at, base: range.upperBound),
              case .uint(let nodes)? = meta["node_count"], case .uint(let record)? = meta["record_size"] else { return nil }
        nodeCount = Int(nodes)
        recordSize = Int(record)
        if case .uint(let v)? = meta["ip_version"] { ipVersion = Int(v) } else { ipVersion = 6 }
        guard [24, 28, 32].contains(recordSize) else { return nil }
        treeSize = nodeCount * recordSize / 4
        guard treeSize + 16 <= data.count else { return nil }
    }

    /// The strings the database holds for the address (country codes), nil if not an IPv4 address.
    func countries(of address: String) -> [String]? {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4, address.split(separator: ".").count == 4 else { return nil }
        var node = 0
        var bits: [Int] = ipVersion == 6 ? Array(repeating: 0, count: 96) : []
        for octet in octets { for i in (0..<8).reversed() { bits.append(Int(octet >> UInt8(i)) & 1) } }
        for bit in bits {
            guard node < nodeCount else { break }
            node = record(node, bit)
        }
        guard node > nodeCount else { return [] }
        var at = data.startIndex + treeSize + (node - nodeCount)
        guard let value = Self.decode(data, &at, base: data.startIndex + treeSize + 16) else { return nil }
        return value.strings
    }

    private func record(_ node: Int, _ bit: Int) -> Int {
        let base = data.startIndex + node * recordSize / 4
        func byte(_ i: Int) -> Int { Int(data[base + i]) }
        switch recordSize {
        case 24: return bit == 0 ? byte(0) << 16 | byte(1) << 8 | byte(2) : byte(3) << 16 | byte(4) << 8 | byte(5)
        case 28: return bit == 0 ? (byte(3) & 0xf0) << 20 | byte(0) << 16 | byte(1) << 8 | byte(2)
                                  : (byte(3) & 0x0f) << 24 | byte(4) << 16 | byte(5) << 8 | byte(6)
        default: return bit == 0 ? byte(0) << 24 | byte(1) << 16 | byte(2) << 8 | byte(3)
                                  : byte(4) << 24 | byte(5) << 16 | byte(6) << 8 | byte(7)
        }
    }

    indirect enum Value {
        case string(String), uint(UInt64), map([String: Value]), array([Value]), other

        var strings: [String] {
            switch self {
            case .string(let s): [s]
            case .array(let a): a.flatMap(\.strings)
            case .map(let m): (m["country"].map { $0.strings } ?? []) + (m["iso_code"]?.strings ?? [])
            default: []
            }
        }
    }

    /// One value at `at` (moved past it); pointers are relative to `base`, the data section.
    static func decode(_ data: Data, _ at: inout Int, base: Int, depth: Int = 0) -> Value? {
        guard depth < 32, at < data.endIndex else { return nil }
        let control = Int(data[at])
        at += 1
        var type = control >> 5
        if type == 1 {  // pointer
            let size = (control >> 3) & 3
            let extra = size + 1
            guard at + extra <= data.endIndex else { return nil }
            var pointer = size == 3 ? 0 : control & 7
            for i in 0..<extra { pointer = pointer << 8 | Int(data[at + i]) }
            pointer += [0, 2048, 526336, 0][size]
            at += extra
            var target = base + pointer
            return decode(data, &target, base: base, depth: depth + 1)
        }
        if type == 0 {
            guard at < data.endIndex else { return nil }
            type = 7 + Int(data[at])
            at += 1
        }
        var size = control & 0x1f
        if size >= 29 {
            let extra = size - 28
            guard at + extra <= data.endIndex else { return nil }
            var n = 0
            for i in 0..<extra { n = n << 8 | Int(data[at + i]) }
            size = [29, 285, 65821][extra - 1] + n
            at += extra
        }
        switch type {
        case 2:
            guard at + size <= data.endIndex else { return nil }
            defer { at += size }
            return .string(String(decoding: data[at..<at + size], as: UTF8.self))
        case 5, 6, 9, 10:
            guard at + size <= data.endIndex, size <= 8 else { at += size; return .other }
            var n: UInt64 = 0
            for i in 0..<size { n = n << 8 | UInt64(data[at + i]) }
            at += size
            return .uint(n)
        case 7:
            var map: [String: Value] = [:]
            for _ in 0..<size {
                guard case .string(let key)? = decode(data, &at, base: base, depth: depth + 1),
                      let value = decode(data, &at, base: base, depth: depth + 1) else { return nil }
                map[key] = value
            }
            return .map(map)
        case 11:
            var list: [Value] = []
            for _ in 0..<size {
                guard let value = decode(data, &at, base: base, depth: depth + 1) else { return nil }
                list.append(value)
            }
            return .array(list)
        case 14:
            return .other   // bool: the value is the size
        case 3: at += 8; return .other
        case 15: at += 4; return .other
        default: at += size; return .other
        }
    }
}

/// What install.sh did with the bundled geodata (#27): `core/geodata`, one "<file>=ok|mismatch|
/// unpinned" per file. A file that was not the pinned one was not installed; the old one stays.
enum GeoDataInstall {
    static let path = "/Library/KillSwitch/core/geodata"

    /// One sentence per file that did not update; empty when all is well or nothing is known.
    static func problems(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1] == "mismatch" || parts[1] == "unpinned" else { return nil }
            let name: String
            switch parts[0] {
            case "geosite.dat": name = String(localized: "База категорий сайтов")
            case "geoip.metadb", "geoip.dat": name = String(localized: "База стран")
            default: return nil
            }
            return String(localized: "\(name) не обновилась: файл в программе не прошёл проверку, работает прежняя. Скачай KillSwitch заново.")
        }
    }
}

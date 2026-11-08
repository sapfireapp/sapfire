import CryptoKit
import Foundation
import Security

// MARK: - Подпись расширений Chrome (CRX3)

/// .crx — ZIP с заголовком, в заголовке подписи (protobuf CrxFileHeader).
/// Подписано: "CRX3 SignedData\0" + длина signed_header_data (4 байта, little-endian) + signed_header_data + сам ZIP.
/// ID расширения — первые 16 байт SHA-256 от открытого ключа разработчика, цифры 0–f записаны буквами a–p:
/// подпись этим ключом и есть «это расширение с этим ID». Магазин Chrome добавляет вторую подпись — своим ключом.
/// Проверка по образцу Chrome (components/crx_file/crx_verifier.cc): все подписи в заголовке должны сходиться,
/// среди них — подпись ключом, от которого получается crx_id.
enum CRX {
    struct Verified {
        let id: String          // ID расширения (32 буквы a–p)
        let fromStore: Bool     // есть подпись магазина Chrome Web Store
        let zip: Data
    }

    enum Failure: LocalizedError {
        case notCRX, oldFormat, broken, badSignature, noDeveloperKey
        var errorDescription: String? {
            switch self {
            case .notCRX: "This isn’t a Chrome extension file."
            case .oldFormat: "This extension uses the old CRX2 format, which has no trustworthy signature. Chrome stopped accepting it in 2019."
            case .broken: "The extension file is damaged."
            case .badSignature: "The extension’s signature doesn’t match its contents — the file was changed after it was signed."
            case .noDeveloperKey: "The extension isn’t signed by its developer."
            }
        }
    }

    /// SHA-256 открытого ключа магазина Chrome Web Store (тот же, что в Chrome: crx_verifier.cc, kPublisherKeyHash)
    static let storeKeyHash = Data([
        0x61, 0xf7, 0xf2, 0xa6, 0xbf, 0xcf, 0x74, 0xcd, 0x0b, 0xc1, 0xfe, 0x24, 0x97, 0xcc, 0x9b, 0x04,
        0x25, 0x4c, 0x65, 0x8f, 0x79, 0xf2, 0x14, 0x53, 0x92, 0x86, 0x7e, 0xa8, 0x36, 0x63, 0x67, 0xcf,
    ])

    static func isCRX(_ d: Data) -> Bool { d.count > 12 && d.prefix(4) == Data("Cr24".utf8) }

    static func verify(_ d: Data) throws -> Verified {
        let d = Data(d)   // индексы с нуля
        guard isCRX(d) else { throw Failure.notCRX }
        let version = u32(d, 4)
        guard version == 3 else { throw version == 2 ? Failure.oldFormat : Failure.notCRX }
        let size = u32(d, 8)
        guard 12 + size <= d.count else { throw Failure.broken }
        let header = d.subdata(in: 12..<(12 + size))
        let zip = d.subdata(in: (12 + size)..<d.count)

        var rsa: [(key: Data, sig: Data)] = [], ec: [(key: Data, sig: Data)] = []
        var signedData: Data?
        for (field, value) in try fields(header) {
            switch field {
            case 2, 3:
                var key: Data?, sig: Data?
                for (f, v) in try fields(value) { if f == 1 { key = v } else if f == 2 { sig = v } }
                guard let key, let sig else { throw Failure.broken }
                if field == 2 { rsa.append((key, sig)) } else { ec.append((key, sig)) }
            case 10000: signedData = value
            default: break
            }
        }
        guard let signedData, let crxID = try fields(signedData).first(where: { $0.0 == 1 })?.1, crxID.count == 16 else {
            throw Failure.noDeveloperKey
        }

        var message = Data("CRX3 SignedData".utf8) + Data([0])
        var n = UInt32(signedData.count).littleEndian
        message += Data(bytes: &n, count: 4) + signedData + zip

        var developer = false, store = false
        for (proofs, ecdsa) in [(rsa, false), (ec, true)] {
            for p in proofs {
                guard check(p.sig, of: message, spki: p.key, ecdsa: ecdsa) else { throw Failure.badSignature }
                let hash = Data(SHA256.hash(data: p.key))
                if hash.prefix(16) == crxID { developer = true }
                if hash == storeKeyHash { store = true }
            }
        }
        guard developer else { throw Failure.noDeveloperKey }
        let id = String(crxID.flatMap { [$0 >> 4, $0 & 0xf] }.map { Character(UnicodeScalar(UInt8(ascii: "a") + $0)) })
        return Verified(id: id, fromStore: store, zip: zip)
    }

    // MARK: Протокол и ключи

    private static func u32(_ d: Data, _ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }

    /// Поля protobuf с длиной (тип 2); числа (тип 0) пропускаем, остальное — ошибка
    private static func fields(_ d: Data) throws -> [(Int, Data)] {
        let d = Data(d)
        var i = 0, out: [(Int, Data)] = []
        func varint() throws -> Int {
            var v = 0, shift = 0
            while true {
                guard i < d.count, shift < 63 else { throw Failure.broken }
                let b = d[i]; i += 1
                v |= Int(b & 0x7f) << shift
                if b & 0x80 == 0 { return v }
                shift += 7
            }
        }
        while i < d.count {
            let tag = try varint()
            switch tag & 7 {
            case 0: _ = try varint()
            case 2:
                let len = try varint()
                guard len >= 0, i + len <= d.count else { throw Failure.broken }
                out.append((tag >> 3, d.subdata(in: i..<(i + len))))
                i += len
            default: throw Failure.broken
            }
        }
        return out
    }

    /// Открытый ключ в SubjectPublicKeyInfo (DER): SEQUENCE { SEQUENCE алгоритм, BIT STRING ключ }
    private static func check(_ sig: Data, of message: Data, spki: Data, ecdsa: Bool) -> Bool {
        guard let raw = bitString(spki) else { return false }
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: ecdsa ? kSecAttrKeyTypeECSECPrimeRandom : kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(raw as CFData, attrs as CFDictionary, nil) else { return false }
        let alg: SecKeyAlgorithm = ecdsa ? .ecdsaSignatureMessageX962SHA256 : .rsaSignatureMessagePKCS1v15SHA256
        return SecKeyVerifySignature(key, alg, message as CFData, sig as CFData, nil)
    }

    private static func bitString(_ der: Data) -> Data? {
        let d = Data(der)
        var i = 0
        func header() -> (tag: UInt8, len: Int)? {
            guard i + 2 <= d.count else { return nil }
            let tag = d[i]; var len = Int(d[i + 1]); i += 2
            if len & 0x80 != 0 {
                let n = len & 0x7f
                guard n > 0, n <= 4, i + n <= d.count else { return nil }
                len = d[i..<(i + n)].reduce(0) { $0 << 8 | Int($1) }
                i += n
            }
            return i + len <= d.count ? (tag, len) : nil
        }
        guard let outer = header(), outer.tag == 0x30 else { return nil }
        guard let algo = header(), algo.tag == 0x30 else { return nil }
        i += algo.len
        guard let bits = header(), bits.tag == 0x03, bits.len > 1, d[i] == 0 else { return nil }
        return d.subdata(in: (i + 1)..<(i + bits.len))
    }
}

import Foundation
import CommonCrypto

/// ClearKey CENC 解密（AES-CTR / AES-CBC pattern）
enum CENC {

    enum Failure: LocalizedError {
        case noKey(String)
        case badData(String)
        case crypto

        var errorDescription: String? {
            switch self {
            case .noKey(let kid): return "缺少 ClearKey（KID \(kid)）"
            case .badData(let what): return "分片数据异常：\(what)"
            case .crypto: return "解密失败"
            }
        }
    }

    /// 就地解密一个媒体分片（moof+mdat），返回新的 Data。
    static func decrypt(fragment: Data,
                        track: MP4Fragment.Info,
                        info: MP4Crypto.InitInfo,
                        keys: [String: String]) throws -> Data {
        guard !track.crypto.isEmpty else { return fragment }

        let (kid, keyHex) = try resolveKey(info: info, keys: keys)
        guard let key = hexBytes(keyHex), key.count == 16 else {
            throw Failure.badData("key 不是 16 字节")
        }

        let scheme = info.schemeType.lowercased()
        let isCBC = (scheme == "cbcs" || scheme == "cbc1")

        var bytes = [UInt8](fragment)
        let totalSamples = track.sampleSizes.count
        guard totalSamples > 0 else { return fragment }

        var offset = track.dataOffset
        guard offset >= 0, offset <= bytes.count else {
            throw Failure.badData("dataOffset 越界")
        }

        for i in 0..<totalSamples {
            let size = track.sampleSizes[i]
            guard size > 0, offset + size <= bytes.count else { break }
            defer { offset += size }

            let crypto = i < track.crypto.count ? track.crypto[i] : track.crypto.last!
            var sampleKey = key
            // 多 key 场景：同名 KID 由上层保证；这里只支持单 key
            _ = kid

            var iv = crypto.iv
            if iv.isEmpty, let constant = info.constantIV {
                iv = constant
            }
            if isCBC {
                if iv.count < 16 { iv = [UInt8](repeating: 0, count: 16 - iv.count) + iv }
                try decryptCBC(sample: &bytes,
                               start: offset,
                               size: size,
                               subsamples: crypto.subsamples,
                               key: sampleKey,
                               iv: Array(iv.prefix(16)),
                               cryptBlocks: info.cryptByteBlock,
                               skipBlocks: info.skipByteBlock)
            } else {
                var ctrIV: [UInt8]
                if iv.count >= 16 {
                    ctrIV = Array(iv.prefix(16))
                } else {
                    ctrIV = [UInt8](repeating: 0, count: 16 - iv.count) + iv
                }
                try decryptCTR(sample: &bytes,
                               start: offset,
                               size: size,
                               subsamples: crypto.subsamples,
                               key: sampleKey,
                               iv: ctrIV)
            }
        }

        return Data(bytes)
    }

    private static func resolveKey(info: MP4Crypto.InitInfo, keys: [String: String]) throws -> (String, String) {
        if let kid = info.defaultKID {
            let normalized = ClearKeyParser.normalizeHex(kid)
            if let key = keys[normalized] ?? keys.first(where: { ClearKeyParser.normalizeHex($0.key) == normalized })?.value {
                return (normalized, key)
            }
        }
        if keys.count == 1, let only = keys.first {
            return (only.key, only.value)
        }
        throw Failure.noKey(info.defaultKID ?? "unknown")
    }

    // MARK: - AES-CTR

    private static func decryptCTR(sample: inout [UInt8],
                                   start: Int,
                                   size: Int,
                                   subsamples: [(clear: Int, encrypted: Int)],
                                   key: [UInt8],
                                   iv: [UInt8]) throws {
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt),
                                        CCMode(kCCModeCTR),
                                        CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding),
                                        ivPtr.baseAddress,
                                        keyPtr.baseAddress,
                                        key.count,
                                        nil, 0, 0,
                                        CCModeOptions(kCCModeOptionCTR_BE),
                                        &cryptor)
            }
        }
        guard status == kCCSuccess, let cryptor = cryptor else { throw Failure.crypto }
        defer { CCCryptorRelease(cryptor) }

        func process(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            let length = range.count
            var out = [UInt8](repeating: 0, count: length)
            var moved = 0
            sample.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                let src = base.advanced(by: range.lowerBound)
                out.withUnsafeMutableBytes { outRaw in
                    CCCryptorUpdate(cryptor, src, length, outRaw.baseAddress, length, &moved)
                    memcpy(src, outRaw.baseAddress!, min(moved, length))
                }
            }
        }

        if subsamples.isEmpty {
            process(start..<(start + size))
        } else {
            var pos = start
            for sub in subsamples {
                let clear = min(sub.clear, max(0, start + size - pos))
                pos += clear
                let enc = min(sub.encrypted, max(0, start + size - pos))
                process(pos..<(pos + enc))
                pos += enc
                if pos >= start + size { break }
            }
        }
    }

    // MARK: - AES-CBC（cbcs pattern）

    private static func decryptCBC(sample: inout [UInt8],
                                   start: Int,
                                   size: Int,
                                   subsamples: [(clear: Int, encrypted: Int)],
                                   key: [UInt8],
                                   iv: [UInt8],
                                   cryptBlocks: Int,
                                   skipBlocks: Int) throws {
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(CCOperation(kCCDecrypt),
                                        CCMode(kCCModeCBC),
                                        CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding),
                                        ivPtr.baseAddress,
                                        keyPtr.baseAddress,
                                        key.count,
                                        nil, 0, 0,
                                        CCModeOptions(0),
                                        &cryptor)
            }
        }
        guard status == kCCSuccess, let cryptor = cryptor else { throw Failure.crypto }
        defer { CCCryptorRelease(cryptor) }

        let cBlocks = max(cryptBlocks, 1)
        let sBlocks = max(skipBlocks, 0)

        func process(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            let length = range.count - (range.count % 16)
            guard length > 0 else { return }
            var out = [UInt8](repeating: 0, count: length)
            var moved = 0
            sample.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                out.withUnsafeMutableBytes { outRaw in
                    CCCryptorUpdate(cryptor, base.advanced(by: range.lowerBound), length,
                                    outRaw.baseAddress, length, &moved)
                    memcpy(base.advanced(by: range.lowerBound), outRaw.baseAddress!, min(moved, length))
                }
            }
        }

        func processPatterned(_ range: Range<Int>) {
            var pos = range.lowerBound
            let end = range.lowerBound + (range.count - range.count % 16)
            while pos < end {
                let cryptLen = min(cBlocks * 16, end - pos)
                process(pos..<(pos + cryptLen))
                pos += cryptLen
                pos += min(sBlocks * 16, max(0, end - pos))
            }
        }

        if subsamples.isEmpty {
            processPatterned(start..<(start + size))
        } else {
            var pos = start
            for sub in subsamples {
                let clear = min(sub.clear, max(0, start + size - pos))
                pos += clear
                let enc = min(sub.encrypted, max(0, start + size - pos))
                processPatterned(pos..<(pos + enc))
                pos += enc
                if pos >= start + size { break }
            }
        }
    }

    static func hexBytes(_ hex: String) -> [UInt8]? {
        let cleaned = ClearKeyParser.normalizeHex(hex)
        guard cleaned.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}

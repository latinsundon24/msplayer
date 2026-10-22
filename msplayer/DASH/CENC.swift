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
                    // CENC：64 位 IV 放在计数器块的“前 8 字节”（最高有效位），
                    // 后 8 字节置零；计数器在最低 64 位递增。
                    ctrIV = Array(iv) + [UInt8](repeating: 0, count: max(0, 16 - iv.count))
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

    // MARK: - AES-CTR（cenc）

    /// 整段一次性 CTR：以 16 字节为块、计数器从 IV 连续推进（不会因明文间隙错位）。
    /// 再按 subsample 把“明文（clear）”区间还原为原始字节。
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

        // 整段密钥流异或，计数器按 16 字节块连续推进
        var out = [UInt8](repeating: 0, count: size)
        var produced = 0
        sample.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            out.withUnsafeMutableBytes { outRaw in
                CCCryptorUpdate(cryptor,
                                base.advanced(by: start),
                                size,
                                outRaw.baseAddress,
                                size,
                                &produced)
            }
        }

        if subsamples.isEmpty {
            // 整段都是加密样本，结果即 out
            sample.replaceSubrange(start..<(start + size), with: out)
            return
        }

        // 还原明文（clear）区间：用原始字节覆盖密钥流异或后的错误结果
        var pos = start
        var outPos = 0
        for sub in subsamples {
            let clear = min(sub.clear, size - (pos - start))
            if clear > 0 {
                for i in 0..<clear { out[outPos + i] = sample[pos + i] }
            }
            pos += clear
            outPos += clear
            let enc = min(sub.encrypted, size - (pos - start))
            pos += enc
            outPos += enc
            if pos >= start + size { break }
        }
        sample.replaceSubrange(start..<(start + size), with: out)
    }

    // MARK: - AES-CBC（cbcs pattern）

    /// cbcs：按 16 字节块逐个处理。crypt 块解密并写回；skip 块仅喂给 CBC 解密器
    /// 以推进链式（CBC 的链式依赖“前一块密文”），但保留原始字节不变（skip 块本就未加密）。
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

        /// 把一个 16 字节对齐的区间交给 CBC 解密器，返回解密结果（同时推进链式）。
        func feed(_ range: Range<Int>) -> [UInt8] {
            let length = range.count - (range.count % 16)
            guard length > 0 else { return [] }
            var out = [UInt8](repeating: 0, count: length)
            var moved = 0
            sample.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                out.withUnsafeMutableBytes { outRaw in
                    CCCryptorUpdate(cryptor,
                                    base.advanced(by: range.lowerBound),
                                    length,
                                    outRaw.baseAddress,
                                    length,
                                    &moved)
                }
            }
            return out
        }

        let sampleEnd = start + size

        if subsamples.isEmpty {
            // 整段加密（无 pattern），一次性解密
            let result = feed(start..<sampleEnd)
            sample.replaceSubrange(start..<sampleEnd, with: result)
            return
        }

        var pos = start
        for sub in subsamples {
            // 明文前导区间：原样跳过
            let clear = min(sub.clear, sampleEnd - pos)
            pos += clear

            // 加密区：crypt cBlocks 块、skip sBlocks 块，循环处理
            var remaining = min(sub.encrypted, sampleEnd - pos)
            while remaining > 0 {
                let cryptTake = min(cBlocks * 16, remaining)
                let cryptAligned = cryptTake - (cryptTake % 16)
                if cryptAligned > 0 {
                    let decrypted = feed(pos..<(pos + cryptAligned))
                    sample.replaceSubrange(pos..<(pos + cryptAligned), with: decrypted)
                    pos += cryptAligned
                    remaining -= cryptAligned
                }
                let skipTake = min(sBlocks * 16, remaining)
                if skipTake > 0 {
                    // 仅推进 CBC 链式，输出丢弃（保留原始未加密字节）
                    _ = feed(pos..<(pos + skipTake))
                    pos += skipTake
                    remaining -= skipTake
                }
                if cryptAligned == 0, skipTake == 0 { break }
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

import XCTest
import Foundation

/// CENC 回归测试：
///   1. `tenc` 声明 ivSize=8 时，即使 `senc` 漏写 per-sample IV flag（0x01），
///      也要按 ivSize 读取 IV（翡翠台 Edgeware 的流就是这样）。
///   2. AES-CTR 只对 protected 区间推进计数器，subsample 之间的 clear 字节不能
///      消耗密钥流，否则 clear 之后的所有数据都会错位（花屏）。
final class CENCTests: XCTestCase {

    private let kid = "00112233445566778899aabbccddeeff"
    private let key = "000102030405060708090a0b0c0d0e0f"

    func testDecryptsLegacySencFlagsAndSkipsClearBytes() throws {
        let fragment = makeFragment()

        var info = MP4Crypto.InitInfo()
        info.isProtected = true
        info.ivSize = 8
        info.defaultKID = kid

        let track = MP4Fragment.parse(fragment, defaults: info)
        XCTAssertEqual(track.sampleSizes, [40])
        XCTAssertEqual(track.crypto.count, 1)
        XCTAssertEqual(track.crypto[0].iv, [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(track.crypto[0].subsamples.count, 1)
        XCTAssertEqual(track.crypto[0].subsamples[0].clear, 8)
        XCTAssertEqual(track.crypto[0].subsamples[0].encrypted, 32)

        let decrypted = try CENC.decrypt(fragment: fragment,
                                         track: track,
                                         info: info,
                                         keys: [kid: key])
        let sample = decrypted.subdata(in: track.dataOffset..<(track.dataOffset + 40))
        XCTAssertEqual(Array(sample), plainSample)
    }

    // MARK: - 合成一个最小 moof + mdat

    private func makeFragment() -> Data {
        let tfhd = fullBox("tfhd", version: 0, flags: 0x020000, be32(1))

        let sencBody = be32(1)
            + Data([1, 2, 3, 4, 5, 6, 7, 8])
            + be16(1)
            + be16(8)
            + be32(32)
        // 注意 flags 故意只写 0x02（subsample），不写 0x01（per-sample IV）。
        let senc = fullBox("senc", version: 0, flags: 0x000002, sencBody)

        func trun(offset: Int32) -> Data {
            let body = be32(1)
                + be32(UInt32(bitPattern: offset))
                + be32(40)
            return fullBox("trun", version: 0, flags: 0x000201, body)
        }

        let placeholderMoof = box("moof", box("traf", tfhd + trun(offset: 0) + senc))
        // mdat 紧跟在 moof 之后，data_offset = moof 大小 + mdat 的 8 字节头。
        let offset = Int32(placeholderMoof.count + 8)
        let moof = box("moof", box("traf", tfhd + trun(offset: offset) + senc))
        let mdat = box("mdat", Data(cipherSample))
        return moof + mdat
    }

    private var plainSample: [UInt8] {
        [0x00, 0x00, 0x00, 0x04, 0x40, 0x01, 0x0c, 0x01]
            + Array(UInt8(0x00)...UInt8(0x1f))
    }

    private var cipherSample: [UInt8] {
        [0x00, 0x00, 0x00, 0x04, 0x40, 0x01, 0x0c, 0x01,
         0x18, 0xbb, 0x6b, 0xb8, 0x42, 0x64, 0xf8, 0xe2,
         0xaf, 0xc5, 0x94, 0xca, 0xab, 0x3c, 0xec, 0x77,
         0xdf, 0x80, 0xbf, 0x8d, 0xc9, 0xec, 0xd8, 0x73,
         0x43, 0x48, 0x44, 0x38, 0x9e, 0xcc, 0xd6, 0xd3]
    }

    // MARK: - Box helpers

    private func be16(_ value: UInt16) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 2)
    }

    private func be32(_ value: UInt32) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 4)
    }

    private func box(_ type: String, _ payload: Data) -> Data {
        var data = be32(UInt32(payload.count + 8))
        data.append(contentsOf: type.utf8.prefix(4))
        data.append(payload)
        return data
    }

    private func fullBox(_ type: String, version: UInt8, flags: UInt32, _ body: Data) -> Data {
        var payload = Data([version,
                            UInt8((flags >> 16) & 0xFF),
                            UInt8((flags >> 8) & 0xFF),
                            UInt8(flags & 0xFF)])
        payload.append(body)
        return box(type, payload)
    }
}

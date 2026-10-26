import Foundation

/// 极简 ISO BMFF (MP4) 盒子解析 / 重写工具。
///
/// 用途：
///   1. 从 moov 中取 trex 默认值、stsd 编码串、encv/enca 样本入口；
///   2. 去掉加密信令（sinf / pssh），使 AVPlayer 把分片当作明流播放；
///   3. 定位 moof 中的 traf/trun/tfhd/senc/saiz/saio 以便解密。
struct Box {
    var type: String
    var payload: Data        // 不含 8 字节头（64 位大小时为 16 字节头）
    var children: [Box]?     // 仅容器盒

    var totalSize: Int { 8 + payload.count }

    static let containers: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "moof", "traf", "mvex",
        "edts", "dinf", "sinf", "schi", "stsd", "mfra", "udta", "meta", "wave"
    ]

    /// 解析一段数据中的顶层盒子
    static func parse(_ data: Data) -> [Box] {
        parse(data, from: 0)
    }

    /// 从指定偏移开始解析（样本入口前有固定字段）
    static func parse(_ data: Data, from start: Int) -> [Box] {
        var boxes: [Box] = []
        var offset = start
        let bytes = [UInt8](data)
        while offset + 8 <= bytes.count {
            var size = Int(be32(bytes, offset))
            let type = fourCC(bytes, offset + 4)
            var headerSize = 8
            if size == 1 {
                guard offset + 16 <= bytes.count else { break }
                size = Int(be64(bytes, offset + 8))
                headerSize = 16
            } else if size == 0 {
                size = bytes.count - offset
            }
            guard size >= headerSize, offset + size <= bytes.count else { break }
            let payload = Data(bytes[(offset + headerSize)..<(offset + size)])
            var children: [Box]? = nil
            if containers.contains(type), type != "stsd" {
                children = Box.parse(payload)
            }
            boxes.append(Box(type: type, payload: payload, children: children))
            offset += size
        }
        return boxes
    }

    /// 序列化（自动重算容器尺寸）
    static func serialize(_ boxes: [Box]) -> Data {
        var out = Data()
        for box in boxes {
            var body: Data
            if let children = box.children {
                body = Box.serialize(children)
            } else {
                body = box.payload
            }
            let size = body.count + 8
            out.append(be32Data(UInt32(size)))
            out.append(fourCCData(box.type))
            out.append(body)
        }
        return out
    }

    // MARK: - 查找

    func child(_ type: String) -> Box? {
        children?.first { $0.type == type }
    }

    func path(_ types: [String]) -> Box? {
        var node: Box? = self
        for type in types {
            node = node?.child(type)
            if node == nil { return nil }
        }
        return node
    }

    /// 跳过 4 字节 full box 头后读 payload
    var bodyAfterFullBox: Data {
        guard payload.count >= 4 else { return Data() }
        return payload.subdata(in: 4..<payload.count)
    }
}

// MARK: - CENC 相关提取

enum MP4Crypto {

    /// 从初始化分片里读取加密信息
    struct InitInfo {
        var schemeType: String = "cenc"     // cenc / cbcs
        var defaultKID: String? = nil
        var ivSize: Int = 8
        var cryptByteBlock: Int = 0
        var skipByteBlock: Int = 0
        var constantIV: [UInt8]? = nil
        var isProtected: Bool = false
        var trackID: UInt32? = nil
        var trexDefaultSampleDuration: UInt32 = 0
        var trexDefaultSampleSize: UInt32 = 0
        var trexDefaultSampleFlags: UInt32 = 0
    }

    /// 解析 moov：取第一条 trak 的 tenc/schm/trex 信息
    static func initInfo(from moovData: Data) -> InitInfo {
        var info = InitInfo()
        let boxes = Box.parse(moovData)
        guard let moov = boxes.first(where: { $0.type == "moov" }) else { return info }

        if let mvex = moov.child("mvex"), let trex = mvex.child("trex") {
            let b = [UInt8](trex.payload)
            if b.count >= 24 {
                info.trexDefaultSampleDuration = be32(b, 12)
                info.trexDefaultSampleSize = be32(b, 16)
                info.trexDefaultSampleFlags = be32(b, 20)
            }
        }

        guard let trak = moov.child("trak"),
              let tkhd = trak.child("tkhd") else { return info }
        let tkhdBytes = [UInt8](tkhd.payload)
        if tkhdBytes.count >= 20 {
            let version = tkhdBytes[0]
            info.trackID = version == 1 ? be32(tkhdBytes, 20) : be32(tkhdBytes, 12)
        }

        if let stsd = trak.path(["mdia", "minf", "stbl", "stsd"]) {
            // stsd: fullbox(4) + entry_count(4) + entries
            let payload = [UInt8](stsd.payload)
            var offset = 8
            while offset + 8 <= payload.count {
                let size = Int(be32(payload, offset))
                let type = fourCC(payload, offset + 4)
                guard size >= 8, offset + size <= payload.count else { break }
                if type == "encv" || type == "enca" {
                    let entry = Data(payload[(offset + 8)..<(offset + size)])
                    let childStart = type == "encv" ? 78 : 28
                    if let sinf = Box.parse(entry, from: childStart).first(where: { $0.type == "sinf" }) {
                        if let schm = sinf.child("schm") {
                            let b = [UInt8](schm.payload)
                            if b.count >= 8 { info.schemeType = fourCC(b, 4) }
                        }
                        if let schi = sinf.child("schi"), let tenc = schi.child("tenc") {
                            let b = [UInt8](tenc.payload)
                            // fullbox(4) reserved(1) [pattern|reserved](1) isProtected(1) ivSize(1) kid(16)
                            if b.count >= 8 {
                                info.isProtected = b[6] == 1
                                info.ivSize = Int(b[7])
                            }
                            if b.count >= 24 {
                                info.defaultKID = b[8..<24].map { String(format: "%02x", $0) }.joined()
                            }
                            if b[0] == 1, b.count >= 6 {
                                info.cryptByteBlock = Int(b[5] >> 4)
                                info.skipByteBlock = Int(b[5] & 0x0F)
                            }
                            if info.isProtected, info.ivSize == 0, b.count >= 25 {
                                let constantSize = Int(b[24])
                                if constantSize > 0, b.count >= 25 + constantSize {
                                    info.constantIV = Array(b[25..<(25 + constantSize)])
                                }
                            }
                        }
                    }
                }
                offset += size
            }
        }
        return info
    }

    /// 去掉 moov 中的加密信令：sinf、pssh，并把 encv/enca 改回 avc1/encv 原始类型？
    /// 说明：保持样本入口四字符码不变（AVPlayer 只按 avc1/hvc1 识别）。
    /// 因此这里同时把 encv -> avc1/hvc1、enca -> mp4a。
    static func stripEncryption(from moovData: Data) -> Data {
        var boxes = Box.parse(moovData)
        guard var moovIndex = boxes.firstIndex(where: { $0.type == "moov" }) else { return moovData }
        var moov = boxes[moovIndex]

        moov.children = moov.children?.filter { $0.type != "pssh" }
        guard var traks = moov.children else { return moovData }

        for i in traks.indices where traks[i].type == "trak" {
            var trak = traks[i]
            guard var children = trak.children else { continue }

            // mdia/minf/stbl/stsd
            if let mdiaIndex = children.firstIndex(where: { $0.type == "mdia" }) {
                var mdia = children[mdiaIndex]
                if var minfChildren = mdia.children,
                   let minfIndex = minfChildren.firstIndex(where: { $0.type == "minf" }) {
                    var minf = minfChildren[minfIndex]
                    if var stblChildren = minf.children,
                       let stblIndex = stblChildren.firstIndex(where: { $0.type == "stbl" }) {
                        var stbl = stblChildren[stblIndex]
                        if var stblKids = stbl.children,
                           let stsdIndex = stblKids.firstIndex(where: { $0.type == "stsd" }) {
                            stblKids[stsdIndex] = stripSampleEntries(stblKids[stsdIndex])
                            stbl.children = stblKids
                        }
                        stblChildren[stblIndex] = stbl
                        minf.children = stblChildren
                    }
                    minfChildren[minfIndex] = minf
                    mdia.children = minfChildren
                }
                children[mdiaIndex] = mdia
            }
            trak.children = children
            traks[i] = trak
        }
        moov.children = traks
        boxes[moovIndex] = moov
        return Box.serialize(boxes)
    }

    private static func stripSampleEntries(_ stsd: Box) -> Box {
        var payload = [UInt8](stsd.payload)
        guard payload.count >= 8 else { return stsd }

        var out = Data(payload[0..<8])
        var offset = 8
        while offset + 8 <= payload.count {
            let size = Int(be32(payload, offset))
            let type = fourCC(payload, offset + 4)
            guard size >= 8, offset + size <= payload.count else { break }
            var entryPayload = Data(payload[(offset + 8)..<(offset + size)])

            if type == "encv" || type == "enca" {
                let childStart = type == "encv" ? 78 : 28
                guard entryPayload.count >= childStart else {
                    out.append(Data(payload[offset..<(offset + size)]))
                    offset += size
                    continue
                }
                var entryBoxes = Box.parse(entryPayload, from: childStart)
                // 保留原始编码类型（frma）。翡翠台是 hev1，改成 hvc1 会与
                // MPD / HLS 中的 CODECS=hev1... 不一致，部分解码器会拒绝。
                let originalType: String? = entryBoxes
                    .first(where: { $0.type == "sinf" })
                    .flatMap { $0.child("frma") }
                    .flatMap { box -> String? in
                        let b = [UInt8](box.payload)
                        return b.count >= 4 ? fourCC(b, 0) : nil
                    }
                entryBoxes.removeAll { $0.type == "sinf" }
                let head = entryPayload.prefix(childStart)
                entryPayload = Data(head) + Box.serialize(entryBoxes)

                let newType: String
                if type == "encv" {
                    if let originalType, ["avc1", "avc3", "hvc1", "hev1"].contains(originalType) {
                        newType = originalType
                    } else {
                        newType = entryPayload.range(of: fourCCData("hvcC")) != nil ? "hvc1" : "avc1"
                    }
                } else {
                    if let originalType, !originalType.isEmpty, originalType != "enca" {
                        newType = originalType
                    } else {
                        newType = "mp4a"
                    }
                }
                out.append(be32Data(UInt32(entryPayload.count + 8)))
                out.append(fourCCData(newType))
                out.append(entryPayload)
            } else {
                out.append(be32Data(UInt32(size)))
                out.append(fourCCData(type))
                out.append(entryPayload)
            }
            offset += size
        }

        out.append(Data(payload[offset...]))
        var result = stsd
        result.payload = out
        result.children = nil
        return result
    }
}

// MARK: - 片段中的样本信息

struct SampleCrypto {
    var iv: [UInt8]
    var subsamples: [(clear: Int, encrypted: Int)]
}

enum MP4Fragment {

    struct Info {
        var moofOffset: Int = 0
        var moofSize: Int = 0
        var trackID: UInt32 = 0
        var dataOffset: Int = 0
        var sampleSizes: [Int] = []
        var sampleDurations: [UInt32] = []
        var sampleFlags: [UInt32] = []
        var crypto: [SampleCrypto] = []
    }

    /// 去掉分片里的加密辅助盒子（senc/saiz/saio），并修正 trun.data_offset。
    /// 解密后这些信息已经没有意义，AVFoundation 对残留信令更敏感。
    static func stripAuxiliaryBoxes(_ fragment: Data) -> Data {
        let bytes = [UInt8](fragment)
        var out = Data()
        var offset = 0
        while offset + 8 <= bytes.count {
            var size = Int(be32(bytes, offset))
            let type = fourCC(bytes, offset + 4)
            var header = 8
            if size == 1 {
                guard offset + 16 <= bytes.count else { break }
                size = Int(be64(bytes, offset + 8))
                header = 16
            } else if size == 0 {
                size = bytes.count - offset
            }
            guard size >= header, offset + size <= bytes.count else { break }
            if type == "moof" {
                out.append(cleanMoof(Data(bytes[offset..<(offset + size)])))
            } else {
                out.append(contentsOf: bytes[offset..<(offset + size)])
            }
            offset += size
        }
        return out.isEmpty ? fragment : out
    }

    private static func cleanMoof(_ moofData: Data) -> Data {
        var boxes = Box.parse(moofData)
        guard let moofIndex = boxes.firstIndex(where: { $0.type == "moof" }),
              var children = boxes[moofIndex].children else { return moofData }

        var removed = 0
        for i in children.indices where children[i].type == "traf" {
            guard var trafChildren = children[i].children else { continue }
            let kept = trafChildren.filter { !["senc", "saiz", "saio"].contains($0.type) }
            removed += trafChildren.reduce(0) { partial, box in
                ["senc", "saiz", "saio"].contains(box.type) ? partial + 8 + box.payload.count : partial
            }
            trafChildren = kept
            children[i].children = trafChildren
        }
        guard removed > 0 else { return moofData }

        for i in children.indices where children[i].type == "traf" {
            guard var trafChildren = children[i].children else { continue }
            for j in trafChildren.indices where trafChildren[j].type == "trun" {
                var payload = [UInt8](trafChildren[j].payload)
                guard payload.count >= 12 else { continue }
                let flags = be32(payload, 0) & 0x00FFFFFF
                guard flags & 0x000001 != 0 else { continue }
                let raw = be32(payload, 8)
                let value = Int32(bitPattern: raw) - Int32(removed)
                let fixed = UInt32(bitPattern: value)
                payload[8] = UInt8((fixed >> 24) & 0xFF)
                payload[9] = UInt8((fixed >> 16) & 0xFF)
                payload[10] = UInt8((fixed >> 8) & 0xFF)
                payload[11] = UInt8(fixed & 0xFF)
                trafChildren[j].payload = Data(payload)
            }
            children[i].children = trafChildren
        }
        boxes[moofIndex].children = children
        return Box.serialize(boxes)
    }

    /// 解析一个媒体分片（moof + mdat）
    static func parse(_ data: Data,
                      defaults: MP4Crypto.InitInfo,
                      ivSizeOverride: Int? = nil) -> Info {
        var info = Info()
        let bytes = [UInt8](data)
        var offset = 0
        var trexDuration = defaults.trexDefaultSampleDuration
        var trexSize = defaults.trexDefaultSampleSize
        var trexFlags = defaults.trexDefaultSampleFlags

        while offset + 8 <= bytes.count {
            var size = Int(be32(bytes, offset))
            let type = fourCC(bytes, offset + 4)
            var header = 8
            if size == 1 {
                if offset + 16 > bytes.count { break }
                size = Int(be64(bytes, offset + 8))
                header = 16
            } else if size == 0 {
                size = bytes.count - offset
            }
            guard size >= header, offset + size <= bytes.count else { break }

            if type == "moof" {
                info.moofOffset = offset
                info.moofSize = size
                parseMoof(Data(bytes[(offset + header)..<(offset + size)]),
                          info: &info,
                          trexDuration: &trexDuration,
                          trexSize: &trexSize,
                          trexFlags: &trexFlags,
                          defaults: defaults,
                          ivSizeOverride: ivSizeOverride)
            }
            offset += size
        }

        // dataOffset 缺省为 moof 结束位置
        if info.dataOffset == 0 {
            info.dataOffset = info.moofOffset + info.moofSize
        }
        return info
    }

    private static func parseMoof(_ payload: Data,
                                  info: inout Info,
                                  trexDuration: inout UInt32,
                                  trexSize: inout UInt32,
                                  trexFlags: inout UInt32,
                                  defaults: MP4Crypto.InitInfo,
                                  ivSizeOverride: Int?) {
        let moofBoxes = Box.parse(payload)
        guard let traf = moofBoxes.first(where: { $0.type == "traf" }) else { return }
        let kids = traf.children ?? []

        var tfhdFlags: UInt32 = 0
        var baseDataOffset: Int? = nil
        var defaultSampleDuration: UInt32? = nil
        var defaultSampleSize: UInt32? = nil
        var defaultSampleFlags: UInt32? = nil
        var trunFlags: UInt32 = 0
        var sampleCount = 0
        var firstSampleFlags: UInt32? = nil
        var dataOffset: Int32 = 0
        var perSampleDurations: [UInt32] = []
        var perSampleSizes: [UInt32] = []
        var perSampleFlags: [UInt32] = []

        for box in kids {
            let b = [UInt8](box.payload)
            switch box.type {
            case "tfhd":
                guard b.count >= 8 else { continue }
                tfhdFlags = be32(b, 0) & 0x00FFFFFF
                info.trackID = be32(b, 4)
                var p = 8
                if tfhdFlags & 0x01 != 0 { p += 8 }               // base-data-offset
                if tfhdFlags & 0x02 != 0 { p += 4 }               // sample-description-index
                if tfhdFlags & 0x08 != 0, p + 4 <= b.count { defaultSampleDuration = be32(b, p); p += 4 }
                if tfhdFlags & 0x10 != 0, p + 4 <= b.count { defaultSampleSize = be32(b, p); p += 4 }
                if tfhdFlags & 0x20 != 0, p + 4 <= b.count { defaultSampleFlags = be32(b, p); p += 4 }
                if tfhdFlags & 0x01 != 0 {
                    let v = be64(b, 8)
                    if v <= UInt64(Int.max) { baseDataOffset = Int(v) }
                }

            case "trun":
                guard b.count >= 8 else { continue }
                trunFlags = be32(b, 0) & 0x00FFFFFF
                sampleCount = Int(be32(b, 4))
                var p = 8
                if trunFlags & 0x000001 != 0, p + 4 <= b.count { dataOffset = Int32(bitPattern: be32(b, p)); p += 4 }
                if trunFlags & 0x000004 != 0, p + 4 <= b.count { firstSampleFlags = be32(b, p); p += 4 }

                let hasDuration = trunFlags & 0x000100 != 0
                let hasSize = trunFlags & 0x000200 != 0
                let hasFlags = trunFlags & 0x000400 != 0
                let hasCTO = trunFlags & 0x000800 != 0

                for i in 0..<sampleCount {
                    if hasDuration, p + 4 <= b.count { perSampleDurations.append(be32(b, p)); p += 4 }
                    if hasSize, p + 4 <= b.count { perSampleSizes.append(be32(b, p)); p += 4 }
                    if hasFlags, p + 4 <= b.count { perSampleFlags.append(be32(b, p)); p += 4 }
                    if hasCTO, p + 4 <= b.count { p += 4 }
                    _ = i
                }

            case "senc":
                guard b.count >= 8 else { continue }
                // senc 是 fullbox：version(1) + flags(3) + sample_count(4)
                let flags = (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
                let hasSubsamples = (flags & 0x02) != 0 // 0x02：携带 subsample 描述
                let count = Int(be32(b, 4))
                let ivLen = ivSizeOverride ?? defaults.ivSize
                var p = 8
                var crypto: [SampleCrypto] = []
                for _ in 0..<count {
                    var iv: [UInt8]
                    // 与 FFmpeg / Bento4 一致：只要 tenc 声明了 per-sample IV 长度，
                    // senc 里就按该长度读取 IV。部分源（翡翠台 Edgeware）的 senc flags
                    // 只写了 0x02（subsample），漏了 0x01，但 IV 仍然实际存在。
                    if ivLen > 0 {
                        guard p + ivLen <= b.count else { break }
                        iv = Array(b[p..<(p + ivLen)])
                        p += ivLen
                    } else if let constant = defaults.constantIV, !constant.isEmpty {
                        iv = constant
                    } else {
                        iv = []
                    }
                    var subs: [(clear: Int, encrypted: Int)] = []
                    if hasSubsamples {
                        guard p + 2 <= b.count else { break }
                        let subCount = Int(be16(b, p)); p += 2
                        for _ in 0..<subCount {
                            guard p + 6 <= b.count else { break }
                            let clear = Int(be16(b, p))
                            let enc = Int(be32(b, p + 2))
                            p += 6
                            subs.append((clear, enc))
                        }
                    }
                    crypto.append(SampleCrypto(iv: iv, subsamples: subs))
                }
                info.crypto = crypto

            default:
                break
            }
        }

        let trackDefaults = defaults
        let durDefault = defaultSampleDuration ?? (trackDefaults.trexDefaultSampleDuration != 0 ? trackDefaults.trexDefaultSampleDuration : trexDuration)
        let sizeDefault = defaultSampleSize ?? (trackDefaults.trexDefaultSampleSize != 0 ? trackDefaults.trexDefaultSampleSize : trexSize)
        let flagsDefault = defaultSampleFlags ?? trackDefaults.trexDefaultSampleFlags

        var sizes: [Int] = []
        var durations: [UInt32] = []
        var flags: [UInt32] = []
        for i in 0..<sampleCount {
            let s = i < perSampleSizes.count ? perSampleSizes[i] : sizeDefault
            let d = i < perSampleDurations.count ? perSampleDurations[i] : durDefault
            let f = i < perSampleFlags.count ? perSampleFlags[i] : (i == 0 ? (firstSampleFlags ?? flagsDefault) : flagsDefault)
            sizes.append(Int(s))
            durations.append(d)
            flags.append(f)
        }

        info.sampleSizes = sizes
        info.sampleDurations = durations
        info.sampleFlags = flags

        if let base = baseDataOffset {
            info.dataOffset = base + Int(dataOffset)
        } else if dataOffset != 0 {
            info.dataOffset = info.moofOffset + Int(dataOffset)
        } else {
            info.dataOffset = info.moofOffset + info.moofSize
        }
    }
}

// MARK: - 字节工具

func be16(_ b: [UInt8], _ o: Int) -> UInt16 {
    guard o + 2 <= b.count else { return 0 }
    return UInt16(b[o]) << 8 | UInt16(b[o + 1])
}

func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
    guard o + 4 <= b.count else { return 0 }
    return UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
}

func be64(_ b: [UInt8], _ o: Int) -> UInt64 {
    guard o + 8 <= b.count else { return 0 }
    return UInt64(be32(b, o)) << 32 | UInt64(be32(b, o + 4))
}

func fourCC(_ b: [UInt8], _ o: Int) -> String {
    guard o + 4 <= b.count else { return "" }
    return String(bytes: b[o..<(o + 4)], encoding: .isoLatin1) ?? ""
}

func be32Data(_ v: UInt32) -> Data {
    var value = v.bigEndian
    return Data(bytes: &value, count: 4)
}

func fourCCData(_ s: String) -> Data {
    var data = Data(s.utf8)
    if data.count < 4 { data.append(contentsOf: [0, 0, 0, 0]) }
    return data.prefix(4)
}

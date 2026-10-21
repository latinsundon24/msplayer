import Foundation
import CoreFoundation

/// 播放列表 / XMLTV 文本解码：UTF-8 优先，失败回退 GB18030。
enum TextDecoding {
    static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        let gbRaw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let text = String(data: data, encoding: String.Encoding(rawValue: gbRaw)) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }
}

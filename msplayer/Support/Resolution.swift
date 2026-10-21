import Foundation
import CoreGraphics

/// 把视频原始分辨率映射成界面上的标准标签。
enum ResolutionLabel {
    static func text(for size: CGSize) -> String? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }
        let shortSide = min(width, height)
        let longSide = max(width, height)

        if longSide >= 3800 || shortSide >= 2100 { return "4K" }
        if shortSide >= 1060 { return "1080P" }
        if shortSide >= 700 { return "720P" }
        if shortSide >= 560 { return "576P" }
        if shortSide >= 460 { return "480P" }
        if shortSide >= 300 { return "\(shortSide)P" }
        return "SD"
    }

    static func text(width: Double, height: Double) -> String? {
        text(for: CGSize(width: width, height: height))
    }
}

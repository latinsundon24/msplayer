import AVFoundation
import Combine
import SwiftUI

/// 清晰度 / 多音轨 / 多字幕选择面板。
///
/// - 清晰度档位来自 `DashPlayback.videoQualities`（MPD 里的多个视频 Representation）。
/// - 音轨 / 字幕来自 `AVPlayerItem` 的 media selection group —— 也就是 `DashPlayback`
///   生成主清单时写进去的那些 `#EXT-X-MEDIA`。
///
/// 两个要点：
/// 1. 打勾依据是从播放器**读回来**的真实生效项：清晰度读上次落地的选择，音轨 / 字幕读
///    `selectedMediaOption`，不是清单里的默认值，所以进来就是当前真正生效的那一项。
/// 2. 行身份用 `key` 而不是标题 —— 多条轨道的显示名有可能完全一样，用标题比较会出现「全都打勾」。
struct TrackSheet: View {

    @ObservedObject var player: PlayerController

    @Environment(\.dismiss) private var dismiss

    @State private var qualityChoices: [PlayerController.VideoQualityChoice] = []
    @State private var qualityKey: String = PlayerController.autoQualityKey
    @State private var audioChoices: [PlayerController.MediaTrackChoice] = []
    @State private var subtitleChoices: [PlayerController.MediaTrackChoice] = []
    @State private var audioKey: String?
    @State private var subtitleKey: String?
    @State private var hint: String?
    @State private var bitrateText = "—"

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        SheetShell("清晰度 · 音轨 · 字幕") {
            qualitySection
            section(title: "音轨",
                    choices: audioChoices,
                    selected: audioKey,
                    isSubtitle: false)
            section(title: "字幕",
                    choices: subtitleChoices,
                    selected: subtitleKey,
                    isSubtitle: true)

            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
        .onAppear { reload() }
        .onReceive(ticker) { _ in refreshBitrate() }
    }

    // MARK: - 子视图

    private var qualitySection: some View {
        CardBox("清晰度") {
            if qualityChoices.isEmpty {
                Text("当前频道只有一档清晰度，或多码率信息未提供")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            } else {
                ForEach(qualityChoices) { choice in
                    Button {
                        pickQuality(choice)
                    } label: {
                        TrackRow(icon: qualityIcon(for: choice),
                                 title: choice.title,
                                 detail: choice.detail,
                                 checked: qualityKey == choice.key)
                    }
                    .buttonStyle(.plain)
                }

                currentLine
            }
        }
    }

    /// 实时校验：把播放器实际输出的分辨率与码率显示出来，切换有没有生效一眼可见
    private var currentLine: some View {
        let actual = player.resolution.isEmpty ? "—" : player.resolution
        return Text("当前实际输出：\(actual) · \(bitrateText)")
            .font(.system(size: 10))
            .foregroundColor(.white.opacity(0.4))
    }

    private func refreshBitrate() {
        guard let value = player.currentPlayingBitrate() else {
            bitrateText = "—"
            return
        }
        let mbps = value / 1_000_000
        bitrateText = mbps >= 1 ? String(format: "%.2f Mbps", mbps) : "\(Int(value / 1000)) kbps"
    }

    private func section(title: String,
                         choices: [PlayerController.MediaTrackChoice],
                         selected: String?,
                         isSubtitle: Bool) -> some View {
        CardBox(choices.isEmpty ? "\(title) · 无可选项" : title) {
            if choices.isEmpty {
                Text(isSubtitle ? "当前频道没有提供多条字幕" : "当前频道没有提供多条音轨")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            } else {
                ForEach(choices) { choice in
                    Button {
                        pick(choice, characteristic: isSubtitle ? .legible : .audible)
                    } label: {
                        TrackRow(icon: trackIcon(for: choice, isSubtitle: isSubtitle),
                                 title: choice.title,
                                 detail: choice.detail,
                                 checked: selected == choice.key)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 交互

    private func reload() {
        hint = nil
        refreshBitrate()
        qualityKey = player.currentVideoQualityKey()
        player.loadVideoQualityChoices { choices in
            qualityChoices = choices
        }
        load(.audible, allowsOff: false) { choices, key in
            audioChoices = choices
            audioKey = key ?? choices.first(where: { !$0.isOff })?.key
        }
        load(.legible, allowsOff: true) { choices, key in
            subtitleChoices = choices
            subtitleKey = key ?? PlayerController.offKey
        }
    }

    private func load(_ characteristic: AVMediaCharacteristic,
                      allowsOff: Bool,
                      apply: @escaping @MainActor ([PlayerController.MediaTrackChoice], String?) -> Void) {
        player.loadMediaTrackChoices(characteristic, allowsOff: allowsOff) { choices in
            player.currentMediaTrackKey(characteristic) { key in
                apply(choices, key)
            }
        }
    }

    private func pick(_ choice: PlayerController.MediaTrackChoice,
                      characteristic: AVMediaCharacteristic) {
        hint = nil
        player.selectMediaTrack(choice.option, characteristic: characteristic) { applied in
            guard let applied else {
                hint = "这一项当前不可用（源端暂时没有提供该轨道）"
                return
            }
            setKey(applied, for: characteristic)
            if applied != choice.key {
                hint = "已切到该项的其他等效轨道"
            }
            // 直播刷新 / 播放器内部调整有可能把它改回去，稍后复核一次显示真实结果
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                resync(characteristic)
            }
        }
    }

    private func pickQuality(_ choice: PlayerController.VideoQualityChoice) {
        hint = nil
        player.selectVideoQuality(choice) { ok in
            guard ok else {
                hint = "当前没有正在播放的视频，无法切换清晰度"
                return
            }
            qualityKey = choice.key
            hint = choice.isAuto ? "已切回自动（由播放器按网络选择）" : "正在切到 \(choice.title)，通常在几秒内生效"
        }
    }

    private func resync(_ characteristic: AVMediaCharacteristic) {
        player.currentMediaTrackKey(characteristic) { key in
            guard let key else { return }
            setKey(key, for: characteristic)
        }
    }

    private func setKey(_ key: String, for characteristic: AVMediaCharacteristic) {
        if characteristic == .audible {
            audioKey = key
        } else {
            subtitleKey = key
        }
    }

    // MARK: - 工具

    private func trackIcon(for choice: PlayerController.MediaTrackChoice, isSubtitle: Bool) -> String {
        if choice.isOff { return "xmark.circle" }
        return isSubtitle ? "captions.bubble" : "waveform"
    }

    private func qualityIcon(for choice: PlayerController.VideoQualityChoice) -> String {
        // 只用基础符号，避免低版本系统缺符号导致图标空一块
        choice.isAuto ? "wand.and.stars" : "tv"
    }
}

/// 面板里的一行：图标 + 标题 + 说明 + 打勾
private struct TrackRow: View {

    let icon: String
    let title: String
    let detail: String?
    let checked: Bool

    init(icon: String, title: String, detail: String?, checked: Bool) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.checked = checked
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(checked ? .cyan : .white.opacity(0.45))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if checked {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.cyan)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

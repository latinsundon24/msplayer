import AVFoundation
import SwiftUI

/// 多音轨 / 多字幕选择面板。
///
/// 选项直接来自 `AVPlayerItem` 的 media selection group —— 也就是 `DashPlayback`
/// 生成主清单时写进去的那些 `#EXT-X-MEDIA`（音轨 / 字幕）。
/// 源端没提供多轨时，对应的分组会显示空提示。
struct TrackSheet: View {

    @ObservedObject var player: PlayerController

    @Environment(\.dismiss) private var dismiss

    @State private var audioChoices: [PlayerController.MediaTrackChoice] = []
    @State private var subtitleChoices: [PlayerController.MediaTrackChoice] = []
    @State private var selectedAudio: String?
    @State private var selectedSubtitle: String?

    var body: some View {
        SheetShell("音轨与字幕") {
            section(title: "音轨",
                    choices: audioChoices,
                    selected: selectedAudio,
                    isSubtitle: false)
            section(title: "字幕",
                    choices: subtitleChoices,
                    selected: selectedSubtitle,
                    isSubtitle: true)
        }
        .onAppear { reload() }
    }

    // MARK: - 子视图

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
                    row(choice, selected: selected, isSubtitle: isSubtitle)
                }
            }
        }
    }

    private func row(_ choice: PlayerController.MediaTrackChoice,
                     selected: String?,
                     isSubtitle: Bool) -> some View {
        Button {
            if isSubtitle {
                selectedSubtitle = choice.title
                player.selectMediaTrack(choice.option, characteristic: .legible)
            } else {
                selectedAudio = choice.title
                player.selectMediaTrack(choice.option, characteristic: .audible)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(for: choice, isSubtitle: isSubtitle))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(selected == choice.title ? .cyan : .white.opacity(0.45))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                    if let detail = choice.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if selected == choice.title {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.cyan)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 工具

    private func icon(for choice: PlayerController.MediaTrackChoice, isSubtitle: Bool) -> String {
        if choice.isOff { return "xmark.circle" }
        return isSubtitle ? "captions.bubble" : "waveform"
    }

    private func reload() {
        let trim = { (text: String?) -> String? in
            let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        selectedAudio = trim(player.defaultMediaTrack(.audible)?.displayName)
        // 字幕默认是没有勾的（清单里写的是 DEFAULT=NO），这里先按「关闭」显示
        selectedSubtitle = trim(player.defaultMediaTrack(.legible)?.displayName) ?? "关闭"

        player.loadMediaTrackChoices(.audible) { choices in
            audioChoices = choices
            if selectedAudio == nil { selectedAudio = choices.first?.title }
        }
        player.loadMediaTrackChoices(.legible, allowsOff: true) { choices in
            subtitleChoices = choices
        }
    }
}

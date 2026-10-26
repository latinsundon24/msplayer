import Foundation
import SwiftUI

struct BottomBar: View {

    let index: Int
    let group: ChannelGroup?
    let lineIndex: Int
    @ObservedObject var player: PlayerController
    let nowProgram: EPGProgram?
    let nextProgram: EPGProgram?
    let onSelectLine: () -> Void
    let onTogglePlay: () -> Void
    let onSeek: (Double) -> Void
    let onShowDiagnostics: () -> Void
    /// 当前频道是否支持时移 / 回看。
    let supportsTimeShift: Bool
    /// 进入时移界面（左右划动同效）。
    let onEnterTimeShift: () -> Void

    @State private var dragging = false
    @State private var dragValue: Double = 0

    private var channel: Channel? {
        player.currentChannel ?? group?.primary
    }

    var body: some View {
        VStack(spacing: 5) {
            topRow
            progressRow
            programRow
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - 第一行

    private var topRow: some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", index))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.cyan.opacity(0.9)))

            Text(channel?.name ?? group?.name ?? "未选择频道")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)

            if let resolution = player.resolution.nonEmpty {
                badge(resolution, color: .green)
            }

            Button(action: onSelectLine) {
                badge("线路 \(lineIndex + 1)/\(max(1, group?.lineCount ?? 1))", color: .orange)
            }
            .buttonStyle(.plain)

            if let format = channel?.formatLabel {
                badge(format, color: .white.opacity(0.55))
            }

            if supportsTimeShift {
                Button(action: onEnterTimeShift) {
                    badge("可时移", color: .cyan)
                }
                .buttonStyle(.plain)
            }

            if player.isPreparing {
                ProgressView().scaleEffect(0.55)
                Text(player.statusText ?? "正在准备…")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
            }

            Spacer(minLength: 4)

            if player.isLive {
                HStack(spacing: 4) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("直播")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.red)
                }
            } else {
                Text(timeText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.65))
            }

            Button(action: onTogglePlay) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)

            Button(action: onShowDiagnostics) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 进度

    private var progressRow: some View {
        Group {
            if player.isLive || player.duration <= 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .frame(height: 3)
                        Capsule()
                            .fill(LinearGradient(colors: [.red.opacity(0.9), .orange],
                                                 startPoint: .leading,
                                                 endPoint: .trailing))
                            .frame(width: max(24, geo.size.width * 0.18), height: 3)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 10)
            } else {
                Slider(
                    value: Binding(
                        get: { dragging ? dragValue : min(max(player.currentTime, 0), player.duration) },
                        set: { dragValue = $0 }
                    ),
                    in: 0...max(player.duration, 0.1),
                    onEditingChanged: { editing in
                        if editing {
                            dragging = true
                            dragValue = player.currentTime
                        } else {
                            dragging = false
                            onSeek(dragValue)
                        }
                    }
                )
                .frame(height: 14)
                .tint(.cyan)
            }
        }
        .frame(height: 14)
    }

    // MARK: - 节目

    private var programRow: some View {
        HStack(spacing: 16) {
            programLabel(title: "正在播放", program: nowProgram, accent: .red)
            programLabel(title: "下一节目", program: nextProgram, accent: .white.opacity(0.55))
            Spacer(minLength: 0)
            if player.isPreparing {
                Text("解码准备中")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            } else if player.backend == .vlc {
                Text("VLC")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
            } else if player.backend == .mpv {
                Text("MPV")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
            } else if player.backend == .system {
                Text("AVPlayer")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .frame(height: 14)
    }

    private func programLabel(title: String, program: EPGProgram?, accent: Color) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(accent.opacity(0.9))
            if let program {
                Text(program.timeRange)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
                Text(program.title)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.78))
                    .lineLimit(1)
            } else {
                Text("暂无节目单")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .lineLimit(1)
    }

    // MARK: - 工具

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private var timeText: String {
        "\(format(player.currentTime)) / \(format(player.duration))"
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 通用容器

struct SheetShell<Content: View>: View {

    let title: String
    let content: Content

    @Environment(\.dismiss) private var dismiss

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .padding(16)
            }
            .background(Color(white: 0.09).ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundColor(.cyan)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct CardBox<Content: View>: View {

    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.45))
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}

private struct DarkField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
    }
}

private extension View {
    func darkField() -> some View { modifier(DarkField()) }
}

private struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = .cyan
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.7 : 1)))
    }
}

private struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.1)))
    }
}

// MARK: - 线路选择

struct LinesSheet: View {

    let group: ChannelGroup?
    let currentLine: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetShell("线路选择") {
            if let group {
                CardBox("\(group.name) · 共 \(group.lineCount) 条线路") {
                    ForEach(Array(group.lines.enumerated()), id: \.offset) { index, line in
                        Button {
                            onSelect(index)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Text("线路 \(index + 1)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(index == currentLine ? .black : .white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(index == currentLine ? Color.cyan : Color.white.opacity(0.12)))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.hostLabel)
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.85))
                                        .lineLimit(1)
                                    Text("\(line.formatLabel) · \(line.hasClearKey ? "ClearKey" : "普通")")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.4))
                                }

                                Spacer(minLength: 4)

                                if index == currentLine {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.cyan)
                                }
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text("请先在频道列表中选择一个频道")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }
}

// MARK: - 列表订阅

struct SubscriptionsSheet: View {

    @EnvironmentObject private var store: Store

    @State private var name = ""
    @State private var url = ""
    @State private var busy = false
    @State private var message: String?
    @State private var showImporter = false

    var body: some View {
        SheetShell("列表订阅") {
            CardBox("已订阅") {
                if store.sources.isEmpty {
                    Text("暂无订阅")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
                ForEach(store.sources) { source in
                    HStack(spacing: 10) {
                        Image(systemName: source.kind == .local ? "folder" : "globe")
                            .foregroundColor(.cyan)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                            Text("\(source.kindLabel) · \(source.count) 个频道")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        if store.selectedSourceID == source.id {
                            Text("当前")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.green)
                        }

                        Button {
                            store.select(source)
                        } label: {
                            Text("使用")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.cyan)
                        }
                        .buttonStyle(.plain)

                        if source.kind == .remote || source.kind == .builtin {
                            Button {
                                Task { await store.refresh(source) }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            store.remove(source)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundColor(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }

            CardBox("添加在线列表") {
                TextField("列表名称（自定义，显示在播放列表）", text: $name)
                    .darkField()
                TextField("m3u / m3u8 / txt 地址（http 或 https）", text: $url)
                    .darkField()
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                HStack(spacing: 10) {
                    Button {
                        addRemote()
                    } label: {
                        Text(busy ? "添加中…" : "添加订阅")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy || url.isEmpty)

                    Button {
                        showImporter = true
                    } label: {
                        Text("导入本地文件")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(busy)

                    if busy { ProgressView().scaleEffect(0.7) }
                }

                Text("支持 m3u / m3u8 / txt；同名频道自动归并为多线路。")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }

            CardBox("格式支持") {
                Text("#KODIPROP:inputstream.adaptive.manifest_type=mpd")
                Text("#KODIPROP:inputstream.adaptive.license_type=clearkey")
                Text("#KODIPROP:inputstream.adaptive.license_key=KID:KEY")
                Text("#EXTVLCOPT:http-user-agent=…")
                Text("#EXTVLCOPT:http-referrer=…")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.white.opacity(0.45))

            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.85))
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
    }

    private func addRemote() {
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        message = nil
        let nameValue = name
        let urlValue = url
        Task {
            do {
                try await store.addRemoteSource(name: nameValue, url: urlValue)
                name = ""
                url = ""
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let fileURL = urls.first else { return }
            let access = fileURL.startAccessingSecurityScopedResource()
            defer { if access { fileURL.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: fileURL)
                let text = HTTPService.decode(data)
                let title = name.isEmpty
                    ? fileURL.deletingPathExtension().lastPathComponent
                    : name
                try store.addLocalSource(name: title, content: text, location: fileURL.lastPathComponent)
                name = ""
                message = nil
            } catch {
                message = "导入失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            message = "导入失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - EPG 订阅

struct EPGSheet: View {

    @EnvironmentObject private var store: Store

    @State private var name = ""
    @State private var url = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        SheetShell("EPG订阅") {
            CardBox("已订阅的 EPG") {
                if store.epgSources.isEmpty {
                    Text("暂无 EPG 源")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
                ForEach(store.epgSources) { source in
                    HStack(spacing: 10) {
                        Image(systemName: "calendar")
                            .foregroundColor(.cyan)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                            Text("\(source.programCount) 个节目 · \(source.url)")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button {
                            Task { await store.refreshEPG(source) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        Button {
                            store.removeEPG(source)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundColor(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }

            CardBox("添加 XMLTV 源") {
                TextField("名称（可选）", text: $name)
                    .darkField()
                TextField("XMLTV / epg.xml 地址", text: $url)
                    .darkField()
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                HStack(spacing: 10) {
                    Button {
                        addEPG()
                    } label: {
                        Text(busy ? "下载中…" : "添加 EPG")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy || url.isEmpty)

                    Button {
                        Task { await store.refreshAllEPG() }
                    } label: {
                        Text("全部刷新")
                    }
                    .buttonStyle(GhostButtonStyle())

                    if busy { ProgressView().scaleEffect(0.7) }
                }
            }

            CardBox("匹配方式") {
                Text("优先使用 tvg-id 匹配；没有 tvg-id 时按频道名称匹配（忽略空格、高清/标清等后缀）。节目单显示在左栏「节目单」与底栏。")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            }

            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.85))
            }
        }
    }

    private func addEPG() {
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        message = nil
        let nameValue = name
        let urlValue = url
        Task {
            do {
                try await store.addEPGSource(name: nameValue, url: urlValue)
                name = ""
                url = ""
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - 显示设置

struct DisplaySheet: View {

    @EnvironmentObject private var store: Store

    var body: some View {
        SheetShell("显示设置") {
            CardBox("画面") {
                Text("画面比例")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                Picker("画面比例", selection: $store.settings.aspect) {
                    ForEach(VideoAspect.allCases) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                .pickerStyle(.segmented)
            }

            CardBox("界面") {
                Toggle(isOn: $store.settings.autoHideSidebars) {
                    Text("播放后自动隐藏边栏").font(.system(size: 13))
                }
                .toggleStyle(SwitchToggleStyle(tint: .cyan))

                if store.settings.autoHideSidebars {
                    HStack {
                        Text("隐藏延时").font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Picker("隐藏延时", selection: $store.settings.autoHideDelay) {
                            Text("3 秒").tag(3.0)
                            Text("4 秒").tag(4.0)
                            Text("6 秒").tag(6.0)
                            Text("10 秒").tag(10.0)
                        }
                        .pickerStyle(.menu)
                    }
                }

                Toggle(isOn: $store.settings.showBottomBar) {
                    Text("显示底部信息栏").font(.system(size: 13))
                }
                .toggleStyle(SwitchToggleStyle(tint: .cyan))

                Text("点击画面可显示/隐藏边栏；底栏包含序号、频道、线路、分辨率、进度与节目信息。")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
    }
}

// MARK: - 解码更换

struct DecoderSheet: View {

    @EnvironmentObject private var store: Store
    @ObservedObject var player: PlayerController
    let onReload: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetShell("解码更换") {
            CardBox("解码器") {
                ForEach(DecoderKind.allCases) { kind in
                    Button {
                        store.settings.decoder = kind
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: store.settings.decoder == kind ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(store.settings.decoder == kind ? .cyan : .white.opacity(0.3))
                                .font(.system(size: 14))
                                .padding(.top, 1)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                Text(kind.detail)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.45))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            CardBox("运行状态") {
                row("VLC 解码库", player.canUseVLC ? "已集成（MobileVLCKit）" : "未集成")
                row("当前解码", backendText)
                row("当前频道", player.currentChannel?.name ?? "—")
                row("播放模式", player.playbackMode)
                row("分辨率", player.resolution.nonEmpty ?? "—")
            }

            CardBox("说明") {
                Text("自动模式：HLS 优先系统解码；RTMP / RTSP / UDP / FLV 自动交给 VLC。系统解码失败会自动回退 VLC。\nDASH + ClearKey 会先由内置解密管线生成本地 HLS，再交给当前解码器播放。")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            }

            Button {
                onReload()
                dismiss()
            } label: {
                Text("应用并重新加载")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var backendText: String {
        switch player.backend {
        case .system: return "系统 AVPlayer"
        case .vlc: return "VLC"
        case .idle: return "未播放"
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
        }
    }
}

// MARK: - 应用设置

struct AppSettingsSheet: View {

    @EnvironmentObject private var store: Store
    @State private var confirmReset = false

    var body: some View {
        SheetShell("应用设置") {
            CardBox("播放") {
                Toggle(isOn: $store.settings.autoPlay) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启动时自动播放").font(.system(size: 13))
                        Text("恢复上次选择的频道").font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: .cyan))
            }

            CardBox("数据") {
                row("订阅列表", "\(store.sources.count)")
                row("频道", "\(store.currentGroups.count)")
                row("线路", "\(store.currentChannels.count)")
                row("EPG 节目", "\(store.epgDatabase?.totalPrograms ?? 0)")

                HStack(spacing: 10) {
                    Button {
                        Task { await store.refreshAll() }
                    } label: {
                        Text("刷新全部列表")
                    }
                    .buttonStyle(GhostButtonStyle())

                    Button {
                        store.clearEPG()
                    } label: {
                        Text("清空 EPG")
                    }
                    .buttonStyle(GhostButtonStyle())
                }
            }

            CardBox("维护") {
                Button {
                    confirmReset = true
                } label: {
                    Text("恢复默认设置")
                }
                .buttonStyle(GhostButtonStyle())

                Text("只重置显示与解码设置，不会删除订阅列表。")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .confirmationDialog("恢复默认设置？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("恢复", role: .destructive) {
                store.settings = .default
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
        }
    }
}

// MARK: - 关于应用

struct AboutSheet: View {

    @ObservedObject var player: PlayerController

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        SheetShell("关于应用") {
            CardBox {
                HStack(spacing: 12) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.cyan)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("msplayer")
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                        Text("版本 \(version)")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    Spacer()
                }
            }

            CardBox("能力") {
                row("解码", "系统 AVPlayer + VLC（MobileVLCKit）")
                row("直播", "HLS / DASH + ClearKey / RTMP / RTSP / UDP / FLV")
                row("列表", "在线与本地 m3u / m3u8 / txt")
                row("EPG", "XMLTV（tvg-id 或频道名匹配）")
                row("画面", "自适应 / 填充 / 拉伸")
            }

            CardBox("内置示例") {
                Text("首次启动会加载内置的离线 ClearKey DASH 演示，无需网络即可验证解密链路。可在「播放列表」切换其他订阅。")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            }

            CardBox("播放诊断") {
                Text(player.diagnosticsText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .textSelection(.enabled)
            }

            CardBox("免责声明") {
                Text("本应用仅提供播放能力，不附带任何频道内容。请确保订阅源与节目单的使用符合当地法律法规。")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.78))
            Spacer(minLength: 0)
        }
    }
}

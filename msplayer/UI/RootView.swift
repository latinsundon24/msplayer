import Foundation
import SwiftUI
import Combine
import UIKit

enum LeftTab: String, CaseIterable, Identifiable {
    case playlists = "播放列表"
    case channels = "频道列表"
    case epg = "节目单"

    var id: String { rawValue }
}

enum MenuSheet: String, Identifiable {
    case lines
    case subscriptions
    case epg
    case display
    case decoder
    case app
    case about

    var id: String { rawValue }
}

struct RootView: View {

    /// 左右栏互斥：任意时刻最多只有一栏显示。
    private enum PanelSide: Equatable {
        case left
        case right
    }

    @EnvironmentObject private var store: Store
    @StateObject private var player = PlayerController()

    @AppStorage("msplayer.lastChannel") private var lastChannelName = ""

    @State private var selectedTab: LeftTab = .channels
    @State private var currentGroup: ChannelGroup?
    @State private var lineIndex = 0
    @State private var visiblePanel: PanelSide?
    @State private var catchUpProgram: EPGProgram?
    @State private var activeSheet: MenuSheet?
    @State private var hideTask: Task<Void, Never>?
    @State private var now = Date()
    @State private var showExitConfirm = false
    @State private var startedOnce = false
    @State private var errorBanner: String?
    @State private var bannerTask: Task<Void, Never>?

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            PlayerSurface(controller: player)

            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { toggleLeft() }
                    .simultaneousGesture(swipeGesture)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { toggleRight() }
                    .simultaneousGesture(swipeGesture)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 0) {
                if visiblePanel == .left {
                    LeftPanel(
                        selectedTab: $selectedTab,
                        currentGroup: currentGroup,
                        channel: activeLineChannel ?? player.currentChannel ?? currentGroup?.primary,
                        now: now,
                        onSelectSource: { source in
                            store.select(source)
                            currentGroup = store.currentGroups.first
                            lineIndex = 0
                            if let group = currentGroup { play(group: group, line: 0) }
                        },
                        onSelectGroup: { group in
                            play(group: group, line: 0)
                        },
                        onSelectProgram: { program in
                            playCatchUp(program)
                        },
                        onCatchUpFrom: { start in
                            playCatchUp(from: start, to: Date())
                        },
                        onInteraction: {
                            notePanelInteraction()
                        }
                    )
                    .frame(width: 300)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                Spacer(minLength: 0)

                if visiblePanel == .right {
                    RightPanel(
                        onSelect: { sheet in activeSheet = sheet },
                        onExit: { showExitConfirm = true }
                    )
                    .frame(width: 200)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if store.settings.showBottomBar {
                    BottomBar(
                        index: currentIndex,
                        group: currentGroup,
                        lineIndex: lineIndex,
                        player: player,
                        nowProgram: nowProgram,
                        nextProgram: nextProgram,
                        onSelectLine: { activeSheet = .lines },
                        onTogglePlay: { player.toggle() },
                        onSeek: { player.seek(to: $0) },
                        onShowDiagnostics: { activeSheet = .about }
                    )
                }
            }

            if let banner = errorBanner {
                VStack {
                    Text(banner)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                        .padding(.top, 14)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { bootstrap() }
        .task {
            await store.reparseAfterUpgrade()
            if let current = store.currentGroups.first(where: { $0.name == currentGroup?.name }) {
                currentGroup = current
                lineIndex = min(lineIndex, max(0, current.lines.count - 1))
            } else if currentGroup == nil {
                currentGroup = store.currentGroups.first
            }
        }
        .onReceive(ticker) { now = $0 }
        .onChange(of: activeLineChannel?.id) { _ in triggerEPG() }
        .onChange(of: store.selectedSourceID) { _ in
            if currentGroup == nil || !store.currentGroups.contains(where: { $0.name == currentGroup?.name }) {
                currentGroup = store.currentGroups.first
                lineIndex = 0
            }
        }
        .onChange(of: player.errorMessage) { message in
            guard let message else { return }
            showBanner(message)
        }
        .onChange(of: store.settings.aspect) { aspect in
            player.aspect = aspect
        }
        .onChange(of: activeSheet == nil) { isNil in
            // 弹出的面板（列表订阅 / EPG / 关于等）关闭后重新计时；
            // 面板打开期间不自动隐藏侧栏。
            hideTask?.cancel()
            if isNil { scheduleAutoHide() }
        }
        .onChange(of: showExitConfirm) { isShowing in
            hideTask?.cancel()
            if !isShowing { scheduleAutoHide() }
        }
        .onDisappear {
            hideTask?.cancel()
            bannerTask?.cancel()
            player.stopCurrent()
        }
        .sheet(item: $activeSheet) { sheet in
            sheetView(sheet)
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
        .confirmationDialog("确定退出 msplayer？", isPresented: $showExitConfirm, titleVisibility: .visible) {
            Button("退出应用", role: .destructive) {
                player.stopCurrent()
                exit(0)
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 子视图

    @ViewBuilder
    private func sheetView(_ sheet: MenuSheet) -> some View {
        switch sheet {
        case .lines:
            LinesSheet(group: currentGroup, currentLine: lineIndex) { index in
                guard let group = currentGroup else { return }
                play(group: group, line: index)
            }
        case .subscriptions:
            SubscriptionsSheet()
        case .epg:
            EPGSheet()
        case .display:
            DisplaySheet()
        case .decoder:
            DecoderSheet(player: player) {
                if let group = currentGroup { play(group: group, line: lineIndex) }
            }
        case .app:
            AppSettingsSheet()
        case .about:
            AboutSheet(player: player)
        }
    }

    // MARK: - 状态

    private var currentIndex: Int {
        guard let group = currentGroup else { return 0 }
        return (store.currentGroups.firstIndex(where: { $0.name == group.name }) ?? 0) + 1
    }

    /// 当前线路的原始频道（保留回看模板，用于判断回看能力）。
    private var activeLineChannel: Channel? {
        guard let group = currentGroup, group.lines.indices.contains(lineIndex) else { return nil }
        return group.lines[lineIndex]
    }

    private var supportsCatchUp: Bool {
        catchUpLine(in: currentGroup) != nil
    }

    /// 当前线路优先；当前线路不支持时，在同频道其他线路里找一条支持回看的。
    private func catchUpLine(in group: ChannelGroup?) -> Int? {
        guard let group else { return nil }
        if group.lines.indices.contains(lineIndex), CatchUp.supports(group.lines[lineIndex]) {
            return lineIndex
        }
        return group.lines.firstIndex(where: { CatchUp.supports($0) })
    }

    private var nowProgram: EPGProgram? {
        if let catchUpProgram { return catchUpProgram }
        guard let channel = player.currentChannel ?? currentGroup?.primary else { return nil }
        return store.programInfo(for: channel, at: now).now
    }

    private var nextProgram: EPGProgram? {
        let channel = activeLineChannel ?? player.currentChannel ?? currentGroup?.primary
        if let catchUpProgram, let channel {
            return store.program(after: catchUpProgram, for: channel)
        }
        guard let channel else { return nil }
        return store.programInfo(for: channel, at: now).next
    }

    /// 切到新频道时，按需触发 JSON EPG 拉取（XMLTV 不需，内部已判断）。
    private func triggerEPG() {
        let channel = activeLineChannel ?? player.currentChannel ?? currentGroup?.primary
        guard let channel, store.epgSources.contains(where: { $0.format == .json }) else { return }
        store.ensureEPG(for: channel, date: Date())
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                handleSwipe(value.translation)
            }
    }

    // MARK: - 行为

    private func bootstrap() {
        guard !startedOnce else { return }
        startedOnce = true

        player.aspect = store.settings.aspect

        player.onPlaybackStarted = {
            scheduleAutoHide()
        }

        let groups = store.currentGroups
        guard !groups.isEmpty else { return }

        let restored = groups.first { $0.name == lastChannelName }
        currentGroup = restored ?? groups.first

        if store.settings.autoPlay, let group = currentGroup {
            play(group: group, line: 0)
        }
    }

    private func play(group: ChannelGroup, line: Int) {
        let safeLine = min(max(0, line), max(0, group.lines.count - 1))
        guard safeLine < group.lines.count else { return }
        currentGroup = group
        lineIndex = safeLine
        lastChannelName = group.name
        catchUpProgram = nil

        let source = group.lines[safeLine]
        var playback = source
        // 回看频道的直播地址去掉 playseek 模板，避免地址里的 ${...} 无法解析。
        if CatchUp.supports(source) {
            playback.url = CatchUp.liveURL(for: source)
        }

        player.aspect = store.settings.aspect
        player.open(channel: playback, lineIndex: safeLine)
        scheduleAutoHide()
    }

    // MARK: - 滑动操作

    private func handleSwipe(_ translation: CGSize) {
        let horizontal = abs(translation.width) > abs(translation.height)
        if horizontal {
            if supportsCatchUp {
                timeshift(by: translation.width > 0 ? 30 : -30)
            } else {
                switchLine(step: translation.width > 0 ? 1 : -1)
            }
        } else {
            switchChannel(step: translation.height < 0 ? 1 : -1)
        }
    }

    /// 上滑 +1，下滑 -1，循环切换。
    private func switchChannel(step: Int) {
        let groups = store.currentGroups
        guard groups.count > 1 else { return }
        let current = currentGroup.flatMap { group in
            groups.firstIndex(where: { $0.name == group.name })
        } ?? 0
        let next = (current + step + groups.count) % groups.count
        let target = groups[next]
        let line = min(lineIndex, max(0, target.lines.count - 1))
        play(group: target, line: line)
    }

    /// 右滑 +1，左滑 -1，循环切换。
    private func switchLine(step: Int) {
        guard let group = currentGroup, group.lines.count > 1 else { return }
        let next = (lineIndex + step + group.lines.count) % group.lines.count
        play(group: group, line: next)
    }

    /// 支持回看的频道：左右滑动做时移。
    private func timeshift(by seconds: Double) {
        guard player.duration > 0 else {
            showBanner("当前为直播，先在「节目单」点选回看节目后再左右滑动时移")
            return
        }
        player.skip(by: seconds)
    }

    /// 从节目单点选节目：用节目起止时间替换 playseek 模板后播放。
    private func playCatchUp(_ program: EPGProgram) {
        let end = min(program.stop, Date())
        if playCatchUp(from: program.start, to: end) {
            catchUpProgram = program
        }
    }

    /// 从指定时间回看到 `end`；成功返回 true。
    @discardableResult
    private func playCatchUp(from start: Date, to end: Date) -> Bool {
        guard let group = currentGroup,
              let line = catchUpLine(in: group),
              group.lines.indices.contains(line) else {
            showBanner("该频道不支持回看")
            return false
        }

        let source = group.lines[line]
        guard let url = CatchUp.url(for: source, from: start, to: end) else {
            showBanner("该频道不支持回看")
            return false
        }

        var playback = source
        playback.url = url
        currentGroup = group
        lineIndex = line
        lastChannelName = group.name
        catchUpProgram = nil

        player.aspect = store.settings.aspect
        player.open(channel: playback, lineIndex: line)
        showBanner("回看 \(clockText(start)) – \(clockText(end))")
        scheduleAutoHide()
        return true
    }

    private func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 左右栏互斥：显示一个时自动隐藏另一个。
    private func toggleLeft() {
        if visiblePanel == .left {
            visiblePanel = nil
            hideTask?.cancel()
        } else {
            visiblePanel = .left
            scheduleAutoHide()
        }
    }

    private func toggleRight() {
        if visiblePanel == .right {
            visiblePanel = nil
            hideTask?.cancel()
        } else {
            visiblePanel = .right
            scheduleAutoHide()
        }
    }

    /// 面板内有任何触摸、滑动、输入时都会调用，重新开始自动隐藏计时。
    /// 只有持续一段时间没有操作，侧栏才会隐藏。
    private func notePanelInteraction() {
        guard visiblePanel != nil, activeSheet == nil, !showExitConfirm else { return }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard store.settings.autoHideSidebars, visiblePanel != nil,
              activeSheet == nil, !showExitConfirm else { return }
        let delay = max(1.5, store.settings.autoHideDelay)
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                visiblePanel = nil
            }
        }
    }

    private func showBanner(_ text: String) {
        bannerTask?.cancel()
        withAnimation { errorBanner = text }
        bannerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { errorBanner = nil }
        }
    }
}

/// 监听滚动视图的 `contentOffset`，用于重置侧栏的自动隐藏计时。
/// 不添加任何手势，不会影响 ScrollView 本身的滚动和按钮点击。
struct ScrollActivityObserver: UIViewRepresentable {
    let onScroll: () -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onScroll = onScroll
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        uiView.onScroll = onScroll
    }

    final class ObserverView: UIView {
        var onScroll: (() -> Void)?
        private var observation: NSKeyValueObservation?
        private var lastFire = Date.distantPast

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attachIfNeeded()
        }

        private func attachIfNeeded() {
            guard observation == nil else { return }

            // ObserverView 通过 .background 挂在 ScrollView 内容之外，UIScrollView 并不是它的
            // 祖先视图，而是某个祖先视图子树里的成员。因此要从自身开始向上遍历祖先，在每个
            // 层级里递归向下搜索 UIScrollView，才能正确挂上 contentOffset 监听。
            // 之前只向上找父视图，永远找不到 ScrollView，导致滚动时从不重置自动隐藏计时，
            // 面板在用户滚动浏览节目单时也会被隐藏。
            var node: UIView? = self
            while let current = node {
                if let scrollView = ObserverView.firstScrollView(in: current) {
                    observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                        self?.onScroll?()
                    }
                    return
                }
                node = current.superview
            }
        }

        private static func firstScrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            for subview in view.subviews {
                if let found = firstScrollView(in: subview) { return found }
            }
            return nil
        }

        deinit {
            observation?.invalidate()
        }
    }
}

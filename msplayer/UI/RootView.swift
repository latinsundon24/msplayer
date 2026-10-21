import Foundation
import SwiftUI
import Combine

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

    @EnvironmentObject private var store: Store
    @StateObject private var player = PlayerController()

    @AppStorage("msplayer.lastChannel") private var lastChannelName = ""

    @State private var selectedTab: LeftTab = .channels
    @State private var currentGroup: ChannelGroup?
    @State private var lineIndex = 0
    @State private var leftVisible = false
    @State private var rightVisible = false
    @State private var catchUpProgram: EPGProgram?
    @State private var activeSheet: MenuSheet?
    @State private var leftHideTask: Task<Void, Never>?
    @State private var rightHideTask: Task<Void, Never>?
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
                if leftVisible {
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
                        }
                    )
                    .frame(width: 300)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                Spacer(minLength: 0)

                if rightVisible {
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
        .animation(.easeInOut(duration: 0.22), value: leftVisible)
        .animation(.easeInOut(duration: 0.22), value: rightVisible)
        .onAppear { bootstrap() }
        .onReceive(ticker) { now = $0 }
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
        .onDisappear {
            leftHideTask?.cancel()
            rightHideTask?.cancel()
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
        activeLineChannel.map(CatchUp.supports) ?? false
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
        guard let group = currentGroup,
              group.lines.indices.contains(lineIndex) else { return }
        let source = group.lines[lineIndex]
        let end = min(program.stop, Date())
        guard let url = CatchUp.url(for: source, from: program.start, to: end) else {
            showBanner("该频道不支持回看")
            return
        }

        var playback = source
        playback.url = url
        currentGroup = group
        lastChannelName = group.name
        catchUpProgram = program

        player.aspect = store.settings.aspect
        player.open(channel: playback, lineIndex: lineIndex)
        scheduleAutoHide()
    }

    /// 左右栏互斥：显示一个时自动隐藏另一个。
    private func toggleLeft() {
        if leftVisible {
            leftVisible = false
            leftHideTask?.cancel()
        } else {
            rightVisible = false
            rightHideTask?.cancel()
            leftVisible = true
            scheduleLeftHide()
        }
    }

    private func toggleRight() {
        if rightVisible {
            rightVisible = false
            rightHideTask?.cancel()
        } else {
            leftVisible = false
            leftHideTask?.cancel()
            rightVisible = true
            scheduleRightHide()
        }
    }

    private func scheduleAutoHide() {
        scheduleLeftHide()
        scheduleRightHide()
    }

    private func scheduleLeftHide() {
        leftHideTask?.cancel()
        guard store.settings.autoHideSidebars, leftVisible else { return }
        let delay = max(1.5, store.settings.autoHideDelay)
        leftHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                leftVisible = false
            }
        }
    }

    private func scheduleRightHide() {
        rightHideTask?.cancel()
        guard store.settings.autoHideSidebars, rightVisible else { return }
        let delay = max(1.5, store.settings.autoHideDelay)
        rightHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                rightVisible = false
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

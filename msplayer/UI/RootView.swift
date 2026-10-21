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
    @State private var overlayVisible = true
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

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleOverlay() }

            HStack(spacing: 0) {
                if overlayVisible {
                    LeftPanel(
                        selectedTab: $selectedTab,
                        currentGroup: currentGroup,
                        channel: player.currentChannel ?? currentGroup?.primary,
                        now: now,
                        onSelectSource: { source in
                            store.select(source)
                            currentGroup = store.currentGroups.first
                            lineIndex = 0
                            if let group = currentGroup { play(group: group, line: 0) }
                        },
                        onSelectGroup: { group in
                            play(group: group, line: 0)
                        }
                    )
                    .frame(width: 300)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                Spacer(minLength: 0)

                if overlayVisible {
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
        .animation(.easeInOut(duration: 0.22), value: overlayVisible)
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

    private var nowProgram: EPGProgram? {
        guard let channel = player.currentChannel ?? currentGroup?.primary else { return nil }
        return store.programInfo(for: channel, at: now).now
    }

    private var nextProgram: EPGProgram? {
        guard let channel = player.currentChannel ?? currentGroup?.primary else { return nil }
        return store.programInfo(for: channel, at: now).next
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
        guard !groups.isEmpty else {
            overlayVisible = true
            return
        }

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

        player.aspect = store.settings.aspect
        player.open(channel: group.lines[safeLine])
        scheduleAutoHide()
    }

    private func toggleOverlay() {
        overlayVisible.toggle()
        if overlayVisible {
            scheduleAutoHide()
        } else {
            hideTask?.cancel()
        }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard store.settings.autoHideSidebars, overlayVisible else { return }
        let delay = max(1.5, store.settings.autoHideDelay)
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                overlayVisible = false
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

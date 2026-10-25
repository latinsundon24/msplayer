import Foundation
import SwiftUI

struct LeftPanel: View {

    @EnvironmentObject private var store: Store

    @Binding var selectedTab: LeftTab
    let currentGroup: ChannelGroup?
    let channel: Channel?
    let now: Date
    let onSelectSource: (Source) -> Void
    let onSelectGroup: (ChannelGroup) -> Void
    let onSelectProgram: (EPGProgram) -> Void
    /// 无 EPG 时的快速回看：从指定时间播到当前时间。
    let onCatchUpFrom: (Date) -> Void
    /// 左栏内有输入等非触摸操作时，重置自动隐藏计时。
    let onInteraction: () -> Void

    @State private var search = ""
    @State private var epgDayOffset = 0

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("", selection: $selectedTab) {
                ForEach(LeftTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Group {
                switch selectedTab {
                case .playlists:
                    playlistList
                case .channels:
                    channelList
                case .epg:
                    epgList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.07).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.leading, 10)
        .padding(.vertical, 10)
        .onChange(of: search) { _ in onInteraction() }
        .onChange(of: selectedTab) { _ in onInteraction() }
        .onChange(of: epgDayOffset) { _ in onInteraction() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("msplayer")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                Text(store.currentSource?.name ?? "未选择列表")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer()
            Button {
                onInteraction()
                if let source = store.currentSource {
                    Task { await store.refresh(source) }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - 播放列表

    private var playlistList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if store.sources.isEmpty {
                    emptyHint("还没有订阅列表\n从右侧「列表订阅」添加在线或本地 m3u / txt")
                }
                ForEach(store.sources) { source in
                    Button {
                        onSelectSource(source)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: source.kind == .local ? "folder" : "globe")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.cyan.opacity(0.9))
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.cyan.opacity(0.12)))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                Text("\(source.kindLabel) · \(source.count) 个频道")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            Spacer(minLength: 4)
                            if store.selectedSourceID == source.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 14))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(store.selectedSourceID == source.id ? Color.white.opacity(0.12) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .background(ScrollActivityObserver { onInteraction() })
        }
    }

    // MARK: - 频道列表

    private var filteredGroups: [ChannelGroup] {
        let all = store.currentGroups
        let keyword = search.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
    }

    private var channelList: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                TextField("搜索频道", text: $search, onEditingChanged: { _ in onInteraction() })
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            .padding(.horizontal, 10)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(filteredGroups.enumerated()), id: \.element.id) { offset, group in
                        channelRow(group: group, index: offset + 1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
                .background(ScrollActivityObserver { onInteraction() })
            }
        }
    }

    private func channelRow(group: ChannelGroup, index: Int) -> some View {
        let active = currentGroup?.name == group.name
        return Button {
            onSelectGroup(group)
        } label: {
            HStack(spacing: 8) {
                Text("\(index)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 26, alignment: .trailing)

                Text(group.name)
                    .font(.system(size: 13, weight: active ? .bold : .regular))
                    .foregroundColor(active ? .cyan : .white)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if group.lines.contains(where: { CatchUp.supports($0) }) {
                    Text("回看")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.16)))
                }
                if group.lineCount > 1 {
                    Text("\(group.lineCount) 线路")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.16)))
                }
                Text(group.primary.formatLabel)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Color.cyan.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 节目单

    private var epgList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if catchUpAvailable {
                        catchUpBar
                    }
                    dayBar
                    if store.epgSources.isEmpty {
                        if catchUpAvailable {
                            emptyHint("尚未订阅 EPG\n可直接用上方「快速回看」，或从右侧「EPG订阅」添加 XMLTV / JSON 地址")
                        } else {
                            emptyHint("尚未订阅 EPG\n从右侧「EPG订阅」添加 XMLTV / JSON 地址")
                        }
                    } else if let channel, !programs(for: channel).isEmpty {
                        let canCatchUp = catchUpAvailable
                        ForEach(programs(for: channel)) { program in
                            programRow(program, canCatchUp: canCatchUp)
                                .id(program.id)
                        }
                    } else if catchUpAvailable {
                        emptyHint("已识别该频道的回看标签，但暂无节目单数据\n可用上方「快速回看」，或在「EPG订阅」添加 EPG 源")
                    } else {
                        emptyHint("该频道暂无节目单数据\n可尝试在「EPG订阅」刷新，或添加更多 EPG 源（XMLTV / JSON）")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .background(ScrollActivityObserver { onInteraction() })
            }
            .onAppear { scrollToCurrent(proxy); ensureEPG() }
            .onChange(of: channel?.id) { _ in scrollToCurrent(proxy); ensureEPG() }
            .onChange(of: epgDayOffset) { _ in scrollToCurrent(proxy); ensureEPG() }
        }
    }

    /// JSON 格式 EPG 是按需逐频道逐日拉取：切换频道 / 日期时触发，Store 内部带缓存。
    private func ensureEPG() {
        guard let channel, store.epgSources.contains(where: { $0.format == .json }) else { return }
        let day = Calendar.current.date(byAdding: .day, value: epgDayOffset, to: now) ?? now
        store.ensureEPG(for: channel, date: day)
    }

    private var catchUpAvailable: Bool {
        if let channel, CatchUp.supports(channel) { return true }
        return currentGroup?.lines.contains(where: { CatchUp.supports($0) }) ?? false
    }

    /// 不依赖 EPG 的快速回看：从 30 分钟 / 1 小时 / 2 小时 / 6 小时 / 24 小时 / 48 小时前播到现在。
    private var catchUpBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("快速回看")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach([30, 60, 120, 360, 1440, 2880], id: \.self) { minutes in
                        Button {
                            onInteraction()
                            onCatchUpFrom(Date().addingTimeInterval(-Double(minutes) * 60))
                        } label: {
                            Text(minutes < 60 ? "\(minutes)分前" : "\(minutes / 60)时前")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.cyan)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.cyan.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(ScrollActivityObserver { onInteraction() })
            }
        }
        .padding(.vertical, 2)
    }

    private var dayBar: some View {
        HStack(spacing: 6) {
            dayButton("昨天", offset: -1)
            dayButton("今天", offset: 0)
            Spacer(minLength: 0)
            Text(dayTitle)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
        }
        .padding(.vertical, 1)
    }

    private func dayButton(_ title: String, offset: Int) -> some View {
        Button {
            epgDayOffset = offset
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(epgDayOffset == offset ? .black : .white.opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(epgDayOffset == offset ? Color.cyan : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    private var dayTitle: String {
        let date = Calendar.current.date(byAdding: .day, value: epgDayOffset, to: now) ?? now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }

    private func programs(for channel: Channel) -> [EPGProgram] {
        // 节目单按整天展示：昨天 / 今天各自 00:00 到 24:00。
        let calendar = Calendar.current
        let reference = calendar.date(byAdding: .day, value: epgDayOffset, to: now) ?? now
        let dayStart = calendar.startOfDay(for: reference)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? reference.addingTimeInterval(12 * 3600)
        let back = now.timeIntervalSince(dayStart) / 3600
        let forward = dayEnd.timeIntervalSince(now) / 3600
        return store.programs(for: channel, hoursBack: back, hoursForward: forward)
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let channel else { return }
        let list = programs(for: channel)
        guard let target = list.first(where: { $0.isCurrent(at: now) })
                ?? list.first(where: { $0.start > now })
                ?? list.first else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(target.id, anchor: .center)
        }
    }

    private func programRow(_ program: EPGProgram, canCatchUp: Bool) -> some View {
        let isNow = program.isCurrent(at: now)
        let available = canCatchUp && program.start <= now
        return Group {
            if available {
                Button {
                    onInteraction()
                    onSelectProgram(program)
                } label: {
                    programRowContent(program, isNow: isNow, canCatchUp: true)
                }
                .buttonStyle(.plain)
            } else {
                programRowContent(program, isNow: isNow, canCatchUp: false)
            }
        }
    }

    private func programRowContent(_ program: EPGProgram, isNow: Bool, canCatchUp: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(EPGProgram.timeFormatter.string(from: program.start))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(isNow ? .red : .white.opacity(0.45))
                .frame(width: 38, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(program.title)
                    .font(.system(size: 12, weight: isNow ? .semibold : .regular))
                    .foregroundColor(isNow ? .white : .white.opacity(0.8))
                    .lineLimit(2)
                if let subtitle = program.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                if isNow {
                    Text("直播中")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                }
                if canCatchUp {
                    Text("回看")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.16)))
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isNow ? Color.white.opacity(0.08) : Color.clear)
        )
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 6) {
            if store.isRefreshing || store.epgRefreshing {
                ProgressView().scaleEffect(0.6)
                Text("正在刷新…")
            } else {
                Text("\(store.currentGroups.count) 个频道 / \(store.currentChannels.count) 条线路")
            }
            Spacer()
            if store.epgDatabase != nil {
                Text("EPG \(store.epgDatabase?.totalPrograms ?? 0)")
            }
            Text(appVersion)
                .foregroundColor(.cyan.opacity(0.55))
        }
        .font(.system(size: 10))
        .foregroundColor(.white.opacity(0.4))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.7"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "8"
        return "v\(short)(\(build))"
    }

    private func emptyHint(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.25))
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 12)
    }
}

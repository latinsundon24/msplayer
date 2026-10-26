import Foundation
import SwiftUI

/// 时移界面。
///
/// 布局（围绕进度条的四角）：
/// ```
///   频道名                              时移 12:30:45
///                                       实时 12:35:20
///   ══════════════●═══════════════════════
///   10-26 新闻联播                   1.0x  列表
/// ```
/// 左右两侧各有一条热区：点一下步进 10 秒，按住不放步进会越来越快；
/// 中间区域点击 = 暂停 / 播放，左右划动同样步进 10 秒。
struct TimeShiftOverlay: View {

    @EnvironmentObject private var store: Store
    @ObservedObject var controller: TimeShiftController

    let channelName: String
    let activeGroup: ChannelGroup?
    let onExit: () -> Void
    let onPlayPause: () -> Void
    let onSelectGroup: (ChannelGroup) -> Void
    /// 隐藏底栏时，用与直播相同的设定唤出左 / 右栏。
    let onToggleLeft: () -> Void
    let onToggleRight: () -> Void
    /// 左右栏是否已打开：打开时整个时移层让位，由底层侧栏点击区负责开 / 关，避免抢手势。
    let panelsOpen: Bool

    @State private var showList = false
    @State private var search = ""
    @State private var dragging = false
    @State private var dragRatio: Double = 0

    private static let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var total: TimeInterval {
        max(controller.windowEnd.timeIntervalSince(controller.windowStart), 1)
    }

    private var playedRatio: Double {
        guard !dragging else { return dragRatio }
        let played = controller.shiftDate.timeIntervalSince(controller.windowStart)
        return min(max(played / total, 0), 1)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()

            // 手势层：左热区 / 中间播放暂停 / 右热区（底栏隐藏或左右栏打开时让位）
            HStack(spacing: 0) {
                TimeShiftStepZone(direction: -1, controller: controller)
                    .frame(width: 106)
                centerZone
                TimeShiftStepZone(direction: 1, controller: controller)
                    .frame(width: 106)
            }
            .ignoresSafeArea()
            .allowsHitTesting(controller.barVisible && !panelsOpen)

            GeometryReader { geo in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    infoBlock
                        .frame(width: max(min(geo.size.width * 0.6, 760), 300))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .padding(.bottom, 14)
            .opacity(controller.barVisible ? 1 : 0)
            .allowsHitTesting(controller.barVisible && !panelsOpen)
            .animation(.easeInOut(duration: 0.25), value: controller.barVisible)

            if showList {
                listPanel
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // 底栏隐藏且左右栏未打开：屏幕退化成直播式交互——左 / 右侧开栏，其余处显栏。
            if !controller.barVisible && !panelsOpen {
                hiddenTapLayer
            }
        }
        .onReceive(Self.ticker) { _ in controller.updateLiveDate() }
        .onAppear { controller.revealBar() }
    }

    /// 底栏隐藏时的透明可触击层：底部区域（原底栏位置）点一下唤出底栏；
    /// 上方左右边缘分别开左 / 右栏，上方中间也唤出底栏。
    private var hiddenTapLayer: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let x = geo.size.width > 0 ? value.location.x / geo.size.width : 0.5
                            let y = geo.size.height > 0 ? value.location.y / geo.size.height : 0.5
                            if y > 0.65 {
                                controller.revealBar()
                            } else if x < 0.25 {
                                onToggleLeft()
                            } else if x > 0.75 {
                                onToggleRight()
                            } else {
                                controller.revealBar()
                            }
                        }
                )
        }
    }

    // MARK: - 中间区域

    private var centerZone: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                controller.revealBar()
                onPlayPause()
            }
            .gesture(
                DragGesture(minimumDistance: 26)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        controller.revealBar()
                        let seconds: TimeInterval = value.translation.width > 0
                            ? TimeShiftController.stepSeconds
                            : -TimeShiftController.stepSeconds
                        controller.step(by: seconds)
                    }
            )
    }

    // MARK: - 信息块

    private var infoBlock: some View {
        VStack(spacing: 5) {
            topRow
            progressBar
            bottomRow
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
    }

    /// 单行：左=频道名；右=「回直播」+ 时移时间 / 实时时间（无标签文字）
    private var topRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(channelName)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 6)

            Button(action: onExit) {
                Text("回直播")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Text(clockText(controller.shiftDate))
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
                    .lineLimit(1)
                Text("/")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                Text(clockText(controller.liveDate))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }

    private var programLine: some View {
        HStack(spacing: 6) {
            Text(dateText(controller.shiftDate))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
            Text(programText)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
        }
    }

    /// 底部左端：加载 / 失败时显示状态，正常时显示日期 + 当前节目
    @ViewBuilder
    private var statusOrProgram: some View {
        switch controller.status {
        case .idle:
            programLine
        case .loading:
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.55)
                Text("时移流加载中…")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.65))
            }
        case .ready:
            programLine
        case .failed(let reason):
            HStack(spacing: 8) {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                Button("重试") { controller.retry() }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.cyan)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 进度条

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 4)
                Capsule()
                    .fill(LinearGradient(colors: [.cyan, .blue],
                                         startPoint: .leading,
                                         endPoint: .trailing))
                    .frame(width: max(0, geo.size.width * playedRatio), height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .offset(x: max(0, geo.size.width * playedRatio - 6))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        dragRatio = Self.ratio(at: value.location.x, width: geo.size.width)
                        controller.revealBar()
                    }
                    .onEnded { value in
                        let ratio = Self.ratio(at: value.location.x, width: geo.size.width)
                        dragging = false
                        controller.revealBar()
                        controller.seek(to: controller.windowStart.addingTimeInterval(total * ratio))
                    }
            )
        }
        .frame(height: 16)
    }

    /// 触点横坐标 → 时间轴比例（宽度异常时兜底为 0，别让除零把 UI 弄坏）。
    private static func ratio(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1)
    }

    /// 单行：左=日期+节目（或加载/错误状态）；右=倍速、列表
    private var bottomRow: some View {
        HStack(alignment: .center, spacing: 8) {
            statusOrProgram
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 6)

            rateMenu

            Button(action: {
                controller.revealBar()
                withAnimation(.easeInOut(duration: 0.2)) { showList.toggle() }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11, weight: .bold))
                    Text("列表")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(showList ? Color.cyan.opacity(0.35) : Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
        }
        .frame(height: 24)
    }

    private var rateMenu: some View {
        Menu {
            ForEach(TimeShiftController.rateOptions, id: \.self) { value in
                Button(action: { controller.setRate(Float(value)) }) {
                    if isSameRate(value) {
                        Label("\(rateLabel(value))x", systemImage: "checkmark")
                    } else {
                        Text("\(rateLabel(value))x")
                    }
                }
            }
        } label: {
            Text("\(rateLabel(Double(controller.rate)))x")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.16)))
        }
    }

    // MARK: - 播放列表

    /// 传入已过滤好的列表，避免在 ForEach 里反复重算（大列表下开销明显）。
    private var listPanel: some View {
        channelListPanel(filteredGroups)
    }

    private func channelListPanel(_ groups: [ChannelGroup]) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                    TextField("搜索频道", text: $search)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .textFieldStyle(.plain)
                    Text("\(groups.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Rectangle().fill(Color.white.opacity(0.06)))

                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(groups.indices, id: \.self) { index in
                            channelRow(index: index + 1, group: groups[index])
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(width: 280)
            .background(Rectangle().fill(Color(white: 0.07).opacity(0.97)))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.leading, 12)
            .padding(.vertical, 12)

            // 面板外侧：点一下收起，不穿透到时移手势
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showList = false } }
        }
    }

    private func channelRow(index: Int, group: ChannelGroup) -> some View {
        let isActive = group.name == activeGroup?.name
        let program = store.programInfo(for: group.primary, at: Date()).now
        return Button(action: { onSelectGroup(group) }) {
            HStack(spacing: 8) {
                Text(String(format: "%02d", index))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(width: 22, height: 16)
                    .background(Capsule().fill(Color.cyan.opacity(0.9)))

                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name)
                        .font(.system(size: 13, weight: isActive ? .bold : .regular))
                        .foregroundColor(isActive ? .cyan : .white.opacity(0.88))
                        .lineLimit(1)
                    if let program {
                        Text(program.title)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.42))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if group.lineCount > 1 {
                    Text("\(group.lineCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Rectangle().fill(isActive ? Color.cyan.opacity(0.12) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 工具

    private var filteredGroups: [ChannelGroup] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = store.currentGroups
        guard !keyword.isEmpty else { return groups }
        return groups.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
    }

    private var programText: String {
        let channel = activeGroup?.primary
        let info = channel.map { store.programInfo(for: $0, at: controller.shiftDate) }
        if let program = info?.now {
            return "\(program.timeRange) \(program.title)"
        }
        return "暂无节目单"
    }

    private func isSameRate(_ value: Double) -> Bool {
        abs(value - Double(controller.rate)) < 0.001
    }

    private func rateLabel(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

    private func clockText(_ date: Date) -> String {
        TimeShiftFormat.clock.string(from: date)
    }

    private func dateText(_ date: Date) -> String {
        TimeShiftFormat.day.string(from: date)
    }
}

// MARK: - 左右热区

/// 点一下步进 10 秒；按住不放会进入连续加速，步长按 10 → 14 → 21 → 30 …递增（上限 240 秒）。
private struct TimeShiftStepZone: View {

    let direction: Int
    @ObservedObject var controller: TimeShiftController

    @State private var accelerating = false
    @State private var cancelled = false
    @State private var pressTask: Task<Void, Never>?

    private let armDelay: UInt64 = 400_000_000
    private let repeatInterval: UInt64 = 320_000_000
    /// 移动超过这个距离就当作划动，不再持续加速
    private let cancelDistance: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [.cyan.opacity(0.55), .clear],
                                     startPoint: direction < 0 ? .leading : .trailing,
                                     endPoint: direction < 0 ? .trailing : .leading))
                .opacity(accelerating ? 0.18 : 0)

            VStack(spacing: 6) {
                Image(systemName: direction < 0 ? "backward.fill" : "forward.fill")
                    .font(.system(size: 26, weight: .bold))
                Text(direction < 0 ? "后退" : "前进")
                    .font(.system(size: 12, weight: .bold))
                Text("\(Int(TimeShiftController.stepSeconds))s")
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundColor(.white.opacity(accelerating ? 0.95 : 0.24))
        }
        .contentShape(Rectangle())
        .gesture(pressGesture)
        .animation(.easeOut(duration: 0.15), value: accelerating)
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !cancelled else { return }
                if abs(value.translation.width) > cancelDistance {
                    cancelled = true
                    stopPress()
                    return
                }
                beginPress()
            }
            .onEnded { _ in
                // 按下那一刻已经给过一次步进，松手不能再补，
                // 否则「点一下」会变成跳 20 秒；持续加速也在这里收尾。
                stopPress()
                cancelled = false
            }
    }

    private func beginPress() {
        guard pressTask == nil else { return }
        // 任意交互都重置底栏自动隐藏计时
        controller.revealBar()
        // 按下立即给一次反馈，别等 0.4 秒才有反应
        controller.step(by: Double(direction) * TimeShiftController.stepSeconds)

        pressTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: armDelay)
            guard !Task.isCancelled else { return }
            accelerating = true
            var count = 0
            // 上限 80 次：万一收不到 onEnded，最多 25 秒后也会自己停下来
            while count < 80, !Task.isCancelled {
                count += 1
                let seconds = min(TimeShiftController.stepSeconds * pow(1.45, Double(count)), 240)
                controller.step(by: Double(direction) * seconds)
                try? await Task.sleep(nanoseconds: repeatInterval)
            }
            // 被取消时 stopPress 已经清理过了，这里不能再动，
            // 否则会把用户紧接着按下时新建的 task 覆盖成 nil（那就再也停不下来了）
            if !Task.isCancelled {
                accelerating = false
                pressTask = nil
            }
        }
    }

    private func stopPress() {
        pressTask?.cancel()
        pressTask = nil
        accelerating = false
    }
}

// MARK: - 时间格式

enum TimeShiftFormat {
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd EEEE HH:mm"
        return formatter
    }()
}

import Foundation
import Combine
import SwiftUI

/// 直播时移控制器。
///
/// 时移复用回看那套 `playseek=开始-结束`：进入时向源站请求一段「过去某刻 → 实时」的流，
/// 这段流有固定时长，之后的左右步进直接在流内 seek，不再重新拉流，所以拖动手感和本地拖动一样。
///
/// 少数源对 playseek 返回的是「从起点一直播下去」的直播式响应（没有时长、无法 seek），
/// 这时自动退化成 `mode == .reload`：每次步进重新取一段流，功能仍在，只是每次要等一次起播。
@MainActor
final class TimeShiftController: ObservableObject {

    enum Status: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    enum Mode: Equatable {
        case seek    // 流内有时长，直接 seek
        case reload  // 每次步进重新取流
        case dash    // DASH 原生时移：源站自带回溯窗口，按墙钟时刻跳转，不重新拉流
    }

    /// 刚进入时移时，时移时间比实时往回退的秒数。
    static let entryDelay: TimeInterval = 4
    /// 单次步进秒数。
    static let stepSeconds: TimeInterval = 10
    /// 可选倍速。
    static let rateOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]

    /// 时移窗口保留的历史长度（单页）。
    private static let historyWindow: TimeInterval = 30 * 60
    /// 向前翻一页的步长：拖到最左端还不够早时，一次往更早推这么多。
    static let extendStep: TimeInterval = 30 * 60
    /// 重新取流时向后保留的余量。
    private static let forwardMargin: TimeInterval = 15 * 60
    /// 起播等待上限。
    private static let loadTimeout: UInt64 = 25_000_000_000
    /// 连续翻页的最小间隔，避免一次拖动里翻好几页。
    private static let extendCooldown: TimeInterval = 0.8

    // MARK: - 对外状态

    @Published private(set) var status: Status = .idle
    @Published private(set) var isActive = false
    @Published private(set) var windowStart = Date()
    @Published private(set) var windowEnd = Date()
    @Published private(set) var shiftDate = Date()
    @Published private(set) var liveDate = Date()
    @Published private(set) var rate: Float = 1
    @Published private(set) var mode: Mode = .seek
    @Published var notice: String?
    /// 时移底栏是否显示；任意交互后重新计时，5 秒无操作自动隐藏。
    @Published var barVisible = true
    private var barHideTask: Task<Void, Never>?

    var isReady: Bool { status == .ready }

    /// 当前页之后还有没有更近的画面可翻（已经贴着实时就不用翻了）
    var canExtendLater: Bool { windowEnd < Date().addingTimeInterval(-60) }

    /// 显示时移底栏并重置自动隐藏计时（任意交互时调用）。
    func revealBar() {
        barVisible = true
        scheduleBarHide()
    }

    /// 5 秒后自动隐藏时移底栏。
    func scheduleBarHide() {
        barHideTask?.cancel()
        barHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            barVisible = false
        }
    }

    private var player: PlayerController?
    private var channel: Channel?
    private var lineIndex: Int = 0
    private var pendingSeek: Date?
    private var reloadTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// 上一次往前翻页的时刻：拖动时 onChanged 每帧都会调 extendEarlier，
    /// 靠这个节流，别一次拖动翻好几页。
    private var lastExtendAt: Date = .distantPast
    /// DASH 翻页是否正在进行
    private var extendingDash = false

    func attach(_ player: PlayerController) {
        self.player = player
    }

    // MARK: - 进入 / 退出

    /// 进入时移：以「实时 - entryDelay」为起点拉一段时移流。
    func enter(channel: Channel, lineIndex: Int) {
        let now = Date()
        liveDate = now
        let anchor = now.addingTimeInterval(-Self.entryDelay)
        reload(channel: channel,
               lineIndex: lineIndex,
               from: anchor.addingTimeInterval(-Self.historyWindow),
               to: now,
               seekTo: anchor)
    }

    /// 重试（起播失败时用）。
    func retry() {
        guard let channel else {
            notice = "无法重试：频道信息已丢失"
            return
        }
        enter(channel: channel, lineIndex: lineIndex)
    }

    /// DASH 原生时移：源站的动态清单本身就在时移缓冲里留着过去几十分钟的分片，
    /// 摊开窗口后直接在当前会话里按播出时刻跳转 —— 不重新拉流，直播不会断。
    func enterDash(channel: Channel, lineIndex: Int) {
        guard let player, player.canDashTimeShift else {
            status = .failed("该频道不支持时移")
            isActive = true
            return
        }
        self.channel = channel
        self.lineIndex = lineIndex
        self.mode = .dash
        self.status = .loading
        self.isActive = true
        self.notice = nil
        self.pendingSeek = nil
        let now = Date()
        self.liveDate = now
        // 首帧就按源站声明的时移深度给范围（7 天就 7 天），真实可拖范围由 refreshDashWindow 校准
        let depth = player.dashTimeShiftEarliest.map { now.timeIntervalSince($0) } ?? Self.historyWindow
        self.windowStart = now.addingTimeInterval(-max(depth, 60))
        self.windowEnd = now
        self.shiftDate = now.addingTimeInterval(-Self.entryDelay)
        self.barVisible = true
        reloadTask?.cancel()
        reloadTask = nil
        scheduleBarHide()

        reloadTask = Task { @MainActor in
            await player.enableDashTimeShift()
            guard !Task.isCancelled, self.isActive, self.mode == .dash else { return }
            // 窗口是起播时就摊开的，这里只给播放器一点时间把状态稳定下来
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, self.isActive, self.mode == .dash else { return }
            self.refreshDashWindow()
            self.status = .ready
            self.seek(to: Date().addingTimeInterval(-Self.entryDelay))
            self.verifyDashSeek()
        }
        armWatchdog()
    }

    /// 回到直播：清掉时移状态并重新拉实时流。
    ///
    /// DASH 原生时移不需要重开流，直接把播放点挪到窗口末端（就是实时）即可。
    func exitToLive() {
        if mode == .dash, let player {
            player.setRate(1)
            // 之前可能翻到了几天前，播放列表得先回到实时那一页，否则跳不回直播
            player.followDashLivePage()
            deactivate()
            Task { @MainActor in
                // 播放列表刷新需要一点时间，等它换到实时分片再定位，不然会跳到旧页
                try? await Task.sleep(nanoseconds: 600_000_000)
                player.seekToDashDate(Date())
                player.play()
            }
            return
        }
        guard let channel = self.channel, let player = self.player else {
            deactivate()
            return
        }
        var live = channel
        live.url = CatchUp.liveURL(for: channel)
        let savedLine = lineIndex
        deactivate()
        player.setRate(1)
        player.open(channel: live, lineIndex: savedLine)
    }

    /// 切台 / 换源：只清状态，播放由外部接管（外部会自己 open）。
    func deactivate() {
        reloadTask?.cancel()
        reloadTask = nil
        watchdog?.cancel()
        watchdog = nil
        pendingSeek = nil
        channel = nil
        extendingDash = false
        lastExtendAt = .distantPast
        barHideTask?.cancel()
        barHideTask = nil
        barVisible = true
        // 倍速是时移界面的功能，退出时一并恢复，别带到下一个频道
        player?.setRate(1)
        status = .idle
        isActive = false
        notice = nil
        rate = 1
    }

    // MARK: - 时移操作

    /// 相对当前时移点步进；正数往实时方向，负数往过去。
    func step(by seconds: TimeInterval) {
        guard status == .ready else { return }
        seek(to: shiftDate.addingTimeInterval(seconds))
    }

    /// 跳到绝对时间点。
    func seek(to target: Date) {
        guard status == .ready else { return }
        let now = Date()
        liveDate = now
        // 时移不能越过实时
        let clamped = min(target, now.addingTimeInterval(-1))
        notice = nil

        if mode == .dash {
            refreshDashWindow()
            // 别让播放点退到窗口之前，否则 AVPlayer 会直接跳回实时
            let earliest = windowStart.addingTimeInterval(2)
            if clamped < earliest {
                // 比这一页更早：往前翻一页，而不是把用户硬卡在页面起点
                extendDashEarlier()
                return
            }
            shiftDate = clamped
            player?.seekToDashDate(clamped)
            if !(player?.isPlaying ?? true) { player?.play() }
            return
        }

        if mode == .seek {
            // 目标比窗口起点还早：把窗口整体往更早扩一页，并直接定位过去。
            // 早期版本这里只夹住不扩展，进度条拖到最左端就再也拉不动了。
            if clamped < windowStart {
                widenEarlier(to: clamped)
                return
            }
            seekWithinStream(to: clamped, now: now)
        } else {
            shiftDate = clamped
            scheduleReload()
        }
    }

    /// 往前翻一页，并定位到这一页的最右端。
    ///
    /// 新页面的终点就是当前页的起点，所以画面从「原来这一段的最开头」接着播过去，
    /// 进度条上的滑块落在**最右端**——用户可以立刻从右往左拖，继续看更早的节目，
    /// 不用先松手再去找位置。不设任何时间上限，一直翻到源站不给流为止。
    private func widenEarlier(to target: Date) {
        guard let channel else { return }
        // 一次至少翻一页；target 比一页还早时按需多翻
        let page = max(Self.extendStep, windowStart.timeIntervalSince(target))
        let newEnd = windowStart
        let newStart = newEnd.addingTimeInterval(-page)
        guard newEnd.timeIntervalSince(newStart) > 120 else { return }
        // 拖到最左端时 target≈旧起点，落在新页最右端；有明确目标时间就定位到目标本身
        let anchor = min(max(target, newStart.addingTimeInterval(1)), newEnd)
        reload(channel: channel,
               lineIndex: lineIndex,
               from: newStart,
               to: newEnd,
               seekTo: anchor)
    }

    /// 界面上把进度条拖到最左端时调用：往前翻一页（可连续触发，节流在内部）。
    func extendEarlier() {
        guard status == .ready else { return }
        if mode == .dash {
            extendDashEarlier()
            return
        }
        guard Date().timeIntervalSince(lastExtendAt) >= Self.extendCooldown else { return }
        lastExtendAt = Date()
        widenEarlier(to: windowStart)
    }

    /// 把进度条拖到最右端时调用：往后翻一页（回到更近的时间）。
    ///
    /// 翻完之后滑块落在新一页的**最左端**，可以接着往右拖——往回走同样不用松手重来。
    func extendLater() {
        guard status == .ready else { return }
        let now = Date()
        if windowEnd >= now.addingTimeInterval(-30) {
            notice = Self.reachedLiveNotice
            return
        }
        guard Date().timeIntervalSince(lastExtendAt) >= Self.extendCooldown else { return }
        lastExtendAt = Date()
        // 一页的宽度沿用当前页，别让翻页节奏忽大忽小
        let page = max(windowEnd.timeIntervalSince(windowStart), Self.extendStep)
        let newStart = windowEnd
        let newEnd = min(newStart.addingTimeInterval(page), now)
        guard newEnd.timeIntervalSince(newStart) > 120 else { return }

        if mode == .dash {
            moveDashPage(endingAt: newEnd,
                         anchor: newStart,
                         failNotice: "已到当前可回看的最新时间")
            return
        }
        guard let channel else { return }
        reload(channel: channel,
               lineIndex: lineIndex,
               from: newStart,
               to: newEnd,
               seekTo: newStart)
    }

    /// DASH 模式往前翻页：让播放列表切换成「以当前页起点结束」的那一段。
    private func extendDashEarlier() {
        guard let player, !extendingDash else { return }
        guard Date().timeIntervalSince(lastExtendAt) >= Self.extendCooldown else { return }
        if let earliest = player.dashTimeShiftEarliest,
           windowStart.timeIntervalSince(earliest) < 30 {
            notice = "已到该频道时移的最早时间（\(TimeShiftFormat.day.string(from: earliest))）"
            return
        }
        lastExtendAt = Date()
        // 新页的终点 = 当前页起点，锚点也在起点：滑块落在新页最右端，从右往左接着拖
        moveDashPage(endingAt: windowStart,
                     anchor: windowStart,
                     failNotice: "已到该频道时移的最早时间")
    }

    /// DASH 换页：让本地播放列表整体切到「以 `end` 结束」的一段，再定位到 `anchor`。
    private func moveDashPage(endingAt end: Date, anchor: Date, failNotice: String) {
        guard let player, !extendingDash else { return }
        extendingDash = true
        notice = nil
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            self.status = .loading
            await player.moveDashTimeShiftPage(endingAt: end)
            guard !Task.isCancelled, self.isActive, self.mode == .dash else {
                self.extendingDash = false
                return
            }
            // 播放列表刚整段换过，给它一点时间生效再定位
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, self.isActive, self.mode == .dash else {
                self.extendingDash = false
                return
            }
            self.refreshDashWindow()
            // 列表没真的挪过去：源站已经不给这一段分片了
            if abs(self.windowEnd.timeIntervalSince(end)) > 120 {
                self.notice = failNotice
                self.status = .ready
                self.extendingDash = false
                return
            }
            let target = min(max(anchor, self.windowStart), self.windowEnd)
            self.shiftDate = target
            player.seekToDashDate(target)
            self.status = .ready
            self.extendingDash = false
        }
        armWatchdog()
    }

    private func seekWithinStream(to target: Date, now: Date) {
        guard let player else { return }
        let duration = player.duration
        var clamped = target
        var position = clamped.timeIntervalSince(windowStart)

        // 已经贴到窗口最前端：停在窗口起点即可；需要更早的画面由 widenEarlier 扩窗口
        if position < 0.5 {
            player.seek(to: 0)
            shiftDate = windowStart
            return
        }

        // 顶到窗口尾部：窗口末尾就是实时时夹住，否则取一段更靠后的流
        if duration > 0, position > duration - 2 {
            if clamped >= now.addingTimeInterval(-2) {
                clamped = windowEnd.addingTimeInterval(-1)
                position = clamped.timeIntervalSince(windowStart)
                notice = "已到实时画面"
            } else {
                reanchor(to: clamped)
                return
            }
        }

        player.seek(to: max(0, position))
        shiftDate = clamped
    }

    func setRate(_ value: Float) {
        rate = value
        player?.setRate(value)
    }

    func updateLiveDate() {
        liveDate = Date()
    }

    // MARK: - 取流

    private func reload(channel: Channel, lineIndex: Int,
                        from: Date, to: Date, seekTo: Date) {
        guard let player, let url = CatchUp.url(for: channel, from: from, to: to) else {
            status = .failed("该频道不支持时移")
            isActive = true
            return
        }
        self.channel = channel
        self.lineIndex = lineIndex
        self.windowStart = from
        self.windowEnd = to
        self.pendingSeek = seekTo
        self.shiftDate = seekTo
        self.notice = nil
        self.status = .loading
        self.isActive = true
        barVisible = true
        scheduleBarHide()

        reloadTask?.cancel()
        reloadTask = nil

        var playback = channel
        playback.url = url
        player.setRate(rate)
        player.open(channel: playback, lineIndex: lineIndex)
        armWatchdog()
    }

    /// 目标时间落在窗口外时，重新取一段以它为中心的流。
    private func reanchor(to target: Date) {
        guard let channel else { return }
        let now = Date()
        let start = target.addingTimeInterval(-Self.historyWindow)
        let end = min(target.addingTimeInterval(Self.forwardMargin), now)
        guard end.timeIntervalSince(start) > 120 else { return }
        reload(channel: channel, lineIndex: lineIndex, from: start, to: end, seekTo: target)
    }

    /// 无法在流内 seek 时，防抖后重新取一段流。
    private func scheduleReload() {
        reloadTask?.cancel()
        let target = shiftDate
        reloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            guard let channel = self.channel else { return }
            self.reload(channel: channel,
                        lineIndex: self.lineIndex,
                        from: target,
                        to: Date(),
                        seekTo: target)
        }
    }

    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.loadTimeout)
            guard !Task.isCancelled else { return }
            if self.status == .loading {
                self.status = .failed("时移流加载超时")
            }
        }
    }

    // MARK: - 播放器状态同步（由界面在主线程驱动）

    func syncDuration(_ duration: Double) {
        guard status == .loading, duration > 0 else { return }
        mode = .seek
        status = .ready
        watchdog?.cancel()
        watchdog = nil
        applyPendingSeek()
    }

    func syncCurrentTime(_ time: Double) {
        guard status != .idle else { return }

        if mode == .dash {
            guard status == .ready, let player, let date = player.dashCurrentDate else { return }
            refreshDashWindow()
            shiftDate = min(date, Date())
            // 播到窗口末端就等于追上了实时，画面会停在那儿，得告诉用户
            if date >= Date().addingTimeInterval(-3), notice != Self.reachedLiveNotice {
                notice = Self.reachedLiveNotice
            }
            return
        }

        if status == .loading {
            // 已经在出画面但始终拿不到时长：按「每次重取」模式用
            if time > 1, (player?.duration ?? 0) <= 0 {
                mode = .reload
                status = .ready
                pendingSeek = nil
                watchdog?.cancel()
                watchdog = nil
                shiftDate = windowStart
            }
            return
        }

        guard status == .ready else { return }

        // 时长刚出现的那一帧，播放器的 isLive 还没翻成 false，seek 会被挡回来；
        // 这里补一次，把落下的那次定位补上（最迟 0.5 秒后生效）。
        if pendingSeek != nil, player?.isLive == false {
            applyPendingSeek()
            return
        }

        guard mode == .seek else { return }
        shiftDate = windowStart.addingTimeInterval(time)

        // 播到窗口末尾就等于追上了实时：画面会停下，得告诉用户为什么
        let duration = player?.duration ?? 0
        if duration > 0, time >= duration - 1, notice != Self.reachedLiveNotice {
            notice = Self.reachedLiveNotice
        }
    }

    /// DASH 窗口会随直播往前挪，每次操作前先同步一次，界面上的拖拽范围才准。
    private func refreshDashWindow() {
        guard let window = player?.dashTimeShiftWindow else { return }
        windowStart = window.start
        windowEnd = window.end
    }

    /// 播放点跳转后复核一次：播放列表还没刷到新窗口时会跳空，此时补一次定位。
    private func verifyDashSeek() {
        let want = shiftDate
        reloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, self.isActive, self.mode == .dash else { return }
            guard let current = self.player?.dashCurrentDate else { return }
            if abs(current.timeIntervalSince(want)) > 8 {
                self.player?.seekToDashDate(want)
            }
        }
    }

    private static let reachedLiveNotice = "已追上实时，点「回直播」继续看直播"

    private func applyPendingSeek() {
        guard let player, let target = pendingSeek else { return }
        // isLive 为真时 PlayerController.seek 会直接返回，这里先别把 pending 清掉，
        // 否则这次定位就丢了，画面会停在时移流的开头。
        guard !player.isLive else { return }
        pendingSeek = nil
        let position = target.timeIntervalSince(windowStart)
        let clamped = min(max(position, 0), max(0, player.duration - 1))
        player.seek(to: clamped)
        shiftDate = target
    }
}

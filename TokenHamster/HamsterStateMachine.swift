//
//  HamsterStateMachine.swift
//  TokenHamster
//
//  纯逻辑层动作状态机 — 管理仓鼠动作、帧动画、触发规则及交互反馈
//  不含任何 UI 代码，可直接被 SwiftUI 的 @StateObject 调用
//

import Foundation
import Combine
import CoreGraphics

// MARK: - 动作枚举

/// 仓鼠所有可播放的动作（不含 tap）
enum HamsterAction: String, CaseIterable {
    case idle
    case eat
    case sleep
    case sleepy
    case happy
    case angry
    case surprised
    case drag
}

// MARK: - 拖拽阶段

enum DragPhase {
    /// 鼠标按下，开始拖拽
    case began
    /// 拖拽移动中
    case changed
    /// 鼠标释放，拖拽结束
    case ended
}

// MARK: - 数据类型（用于 updateData）

enum QuotaOrToken {
    case quota
    case token
}

// MARK: - 帧数据结构

struct Frame {
    let imageName: String
    let duration: TimeInterval
}

// MARK: - HamsterStateMachine

@MainActor
final class HamsterStateMachine: ObservableObject {

    // ============================================================
    // MARK: - 对外暴露的 UI 接口
    // ============================================================

    /// 当前正在播放的动作
    @Published var state: HamsterAction = .idle

    /// 当前帧图片名，UI 层直接用于 `Image(nsImage:)` → `NSImage(named:)`
    @Published var currentImageName: String = "idle_1"

    /// 仓鼠当前位置（由拖拽驱动）
    @Published var position: CGPoint = .zero

    // ============================================================
    // MARK: - 可配置参数
    // ============================================================

    /// 活动范围中心（拖拽落点会更新此值）
    var center: CGPoint = .zero

    /// 懒惰探测器阈值范围（秒），随机取值，超过此时间无交互 → sleepy
    var lazyThresholdMin: TimeInterval = 40
    var lazyThresholdMax: TimeInterval = 50

    /// 自动动作冷却时间（秒），回 idle 后至少等待此时间才能再次触发自动动作
    var cooldownDuration: TimeInterval = 4.0

    /// 连续点击多少次以上触发 angry
    var angryClickThreshold: Int = 5

    /// sleepy 播完后进入 sleep 的概率（0~1）
    var sleepProbability: Double = 0.5

    /// 连续使用（token 消耗）累计多少次后触发嗑瓜子 —— 对应"几次对话"
    var usageStreakThreshold: Int = 3

    /// 两次嗑瓜子之间的最小间隔（秒）—— 防止用户持续使用时一直嗑瓜子
    var eatCooldownDuration: TimeInterval = 1800  // 30 分钟

    /// happy / surprised 各半概率
    var refreshHappyProbability: Double = 0.5

    /// 点击窗口期（秒），在此时间内的点击计入连续计数
    var clickWindowDuration: TimeInterval = 3.0

    // ============================================================
    // MARK: - 帧率配置（每帧持续秒数，越大越慢）
    //
    // 参考 ACTIONS.md §5.1:
    //   idle    4~6 fps   → 0.167~0.25 s/frame
    //   drag    10~12 fps → 0.083~0.10 s/frame
    //   sleep   2~3 fps   → 0.33~0.50 s/frame
    //
    // 需求要求「间隔长一点，不要密集切换」，因此取参考区间上限
    // ============================================================

    private static let frameRateConfig: [HamsterAction: TimeInterval] = [
        .idle:      0.25,   // 4 fps
        .eat:       0.08,   // 仅作兜底基准值；eat 实际走 makeFrames 里逐帧的咀嚼时间表（0.144→0.080s）
        .sleep:     0.40,   // 2.5 fps（最慢）
        .sleepy:    0.40,   // 2.5 fps（打哈欠慢动作）
        .happy:     0.30,   // ~3.3 fps
        .angry:     0.30,   // ~3.3 fps
        .surprised: 0.15,   // ~6.7 fps（惊讶要快）
        .drag:      0.10    // 10 fps（最快）
    ]

    // ============================================================
    // MARK: - 帧数配置（每种动作的独立精灵图张数）
    // ============================================================

    private static let frameCountConfig: [HamsterAction: Int] = [
        .idle:      2,  // 仅呼吸帧 1↔2，眨眼由独立定时器控制
        .eat:       6,  // eat_1（起势）~ eat_6（收势），中间 2~5 为咀嚼帧
        .sleep:     4,
        .sleepy:    4,
        .happy:     4,
        .angry:     4,
        .surprised: 4,
        .drag:      4
    ]

    // ============================================================
    // MARK: - 内部状态
    // ============================================================

    private var frames: [Frame] = []
    private var currentFrameIndex: Int = 0
    private var animationTimer: Timer?
    private var lazyTimer: Timer?
    private var loopPauseTimer: Timer?

    private var lastInteractionTime: Date = Date()
    private var clickCount: Int = 0
    private var clickWindowStart: Date = Date()
    private var cooldownUntil: Date = .distantPast

    /// 连续使用计数 — 每次 token 消耗 +1，达到 usageStreakThreshold 触发嗑瓜子
    private var usageStreak: Int = 0

    /// 上一次嗑瓜子时间 — 用于两次嗑瓜子之间的最小间隔守卫
    private var lastEatTime: Date = .distantPast

    /// 是否正在播放 once 动画（不可被普通点击打断，drag 例外）
    private var isAnimationLocked: Bool = false

    /// 拖拽子系统 — 是否正在被用户拖拽（用于 drag 动画循环判断）
    private var isDragging: Bool = false

    /// sleep 唤醒定时器 — sleep_4 停留结束后触发醒来序列
    private var sleepWakeTimer: Timer?

    /// loop 动画两轮之间的随机暂停范围（秒）
    private let loopPauseMin: TimeInterval = 4.0
    private let loopPauseMax: TimeInterval = 10.0

    /// idle 无聊探测器 — 随机间隔后自动触发一个动作
    private var boredomTimer: Timer?
    private let boredomIntervalMin: TimeInterval = 25.0
    private let boredomIntervalMax: TimeInterval = 40.0

    /// 当前懒惰探测器随机阈值（每次交互后重新随机）
    private var currentLazyThreshold: TimeInterval = 40

    /// 无聊时可触发的动作池
    private let boredomActions: [HamsterAction] = [.eat, .sleepy, .happy, .surprised]

    /// idle 眨眼子系统 — 随机间隔后快速闭眼再睁眼
    private var idleBlinkTimer: Timer?
    private let idleBlinkMinInterval: TimeInterval = 1.0
    private let idleBlinkMaxInterval: TimeInterval = 3.0
    private let idleBlinkDuration: TimeInterval = 0.08  // 极短闭眼

    // ============================================================
    // MARK: - 初始化
    // ============================================================

    init() {
        buildFrames(for: .idle)
        startAnimationLoop()
        randomizeLazyThreshold()
        startLazyDetector()
        scheduleBoredomAction()
    }

    deinit {
        animationTimer?.invalidate()
        lazyTimer?.invalidate()
        loopPauseTimer?.invalidate()
        boredomTimer?.invalidate()
        idleBlinkTimer?.invalidate()
        sleepWakeTimer?.invalidate()
    }

    // ============================================================
    // MARK: - 帧数组构建（动态拼接图片名）
    // ============================================================

    /// 根据动作名拼接 "{action}_{1..N}" 图片名并赋帧时长（写入实例 frames）
    private func buildFrames(for action: HamsterAction) {
        frames = Self.makeFrames(for: action)
    }

    /// 纯函数版帧数组构建 —— 不读写实例状态，因此 `totalDuration(of:)` 也能用它精确求和，
    /// 单测也能直接拿到帧序列 / 时长而不必启动状态机的定时器。
    static func makeFrames(for action: HamsterAction) -> [Frame] {
        let count = frameCountConfig[action] ?? 4
        let baseDuration = frameRateConfig[action] ?? 0.20

        if action == .sleep {
            // 睡觉逐帧放缓：sleep_1(0.5s) → sleep_2(1.0s) → sleep_3(1.5s) → sleep_4(0.5s 过渡到末尾)
            let sleepDurations: [TimeInterval] = [0.5, 1.0, 1.5, 0.5]
            return (0..<count).map { i in
                Frame(
                    imageName: "sleep_\(i + 1)",
                    duration: sleepDurations[min(i, sleepDurations.count - 1)]
                )
            }
        }

        if action == .eat {
            // 嗑瓜子：1 → 2 3 2 3 4 5 4 5 → 6
            //
            //   1           起势：双手举稳瓜子（定格读得清）
            //   2 3 2 3     咬壳：用嘴啃开坚果外壳（两轮开合）
            //   4 5 4 5     咀嚼：腮帮塞满后高频咀嚼（两轮开合）
            //   6           收势：吃完抬头，满足（定格读得清）
            //
            // 咀嚼帧取自 0.144s → 0.080s 的**逐帧加速**（≈7~12.5 fps）：
            // 鼠类真实咀嚼约 5~10 Hz，一个开合 = 两帧，因此
            //   第 1 轮 0.272s/次(≈3.7Hz) → 第 4 轮 0.176s/次(≈5.7Hz)
            // 由「啃壳」到「塞满腮帮猛嚼」越来越急，避免匀速播放的机械感。
            // 全程 0.6 + 0.896 + 0.6 = 2.096s。
            //
            // 2026-09-25 二次调整：原先 0.09→0.05s 观感过快（像抽搐），
            // 整体放慢 1.6 倍后 0.144→0.080s，节奏更接近真实啃咬。
            let chewImages = ["eat_2", "eat_3", "eat_2", "eat_3",
                              "eat_4", "eat_5", "eat_4", "eat_5"]
            let chewDurations: [TimeInterval] = [0.144, 0.128, 0.128, 0.112,
                                                 0.112, 0.096, 0.096, 0.080]
            var eatFrames: [Frame] = [Frame(imageName: "eat_1", duration: 0.60)]
            eatFrames += zip(chewImages, chewDurations).map { (name, duration) in
                Frame(imageName: name, duration: duration)
            }
            eatFrames.append(Frame(imageName: "eat_6", duration: 0.60))
            return eatFrames
        }

        if action == .surprised {
            // 惊讶第2帧停顿：surprised_1(0.15s) → surprised_2(0.6s 停顿) → surprised_3(0.15s) → surprised_4(0.15s)
            let surprisedDurations: [TimeInterval] = [0.15, 0.60, 0.15, 0.15]
            return (0..<count).map { i in
                Frame(
                    imageName: "surprised_\(i + 1)",
                    duration: surprisedDurations[min(i, surprisedDurations.count - 1)]
                )
            }
        }

        if action == .sleepy {
            // 打哈欠逐帧放缓：sleepy_1(0.4s) → sleepy_2(0.7s) → sleepy_3(1.1s) → sleepy_4(1.6s)
            let sleepyDurations: [TimeInterval] = [0.40, 0.70, 1.10, 1.60]
            return (0..<count).map { i in
                Frame(
                    imageName: "sleepy_\(i + 1)",
                    duration: sleepyDurations[min(i, sleepyDurations.count - 1)]
                )
            }
        }

        return (1...count).map { i in
            Frame(
                imageName: "\(action.rawValue)_\(i)",
                duration: baseDuration
            )
        }
    }

    // ============================================================
    // MARK: - 动画循环引擎
    // ============================================================

    /// 启动动画时钟 — 每次按当前帧的 duration 调度下一次触发
    private func startAnimationLoop() {
        animationTimer?.invalidate()
        scheduleNextFrame()
    }

    /// 按当前帧的 duration 延迟后推进到下一帧
    private func scheduleNextFrame() {
        guard !frames.isEmpty else { return }
        let frameDuration = max(frames[currentFrameIndex].duration, 0.05)
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(
            withTimeInterval: frameDuration,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.advanceFrame()
            }
        }
    }

    /// 推进到下一帧；到达末尾时触发 onAnimationComplete
    private func advanceFrame() {
        guard !frames.isEmpty else { return }

        // 拖拽中，到达 drag_3 后冻结，不再前进（等待松手进入 drag_4）
        if state == .drag && isDragging && currentFrameIndex >= 2 {
            currentImageName = frames[2].imageName // 定格 drag_3: 高速拖拽
            return
        }

        currentFrameIndex += 1

        if currentFrameIndex >= frames.count {
            currentFrameIndex = 0
            onAnimationCycleComplete()
            return
        }

        currentImageName = frames[currentFrameIndex].imageName
        scheduleNextFrame()
    }

    /// 一轮动画播放完毕（到达最后一帧后回调）
    private func onAnimationCycleComplete() {
        switch state {
        case .idle:
            // loop 动作 → 随机暂停后继续
            scheduleLoopPause()

        case .sleep:
            // 播完 sleep_4 后定格不动，启动唤醒定时器
            currentImageName = "sleep_4"
            startSleepWakeTimer()

        case .eat, .sleepy, .happy, .angry, .surprised:
            // once 动作 → 回 idle
            if !isAnimationLocked { return }
            isAnimationLocked = false
            setCooldown()
            transitionTo(.idle)

        case .drag:
            // drag 永远不应该自然循环到末尾（到达最后一帧后回 idle）
            // 正常路径：drag_3 冻结 → .ended 触发 4 → 到达末尾进这里
            isAnimationLocked = false
            isDragging = false
            transitionTo(.idle)
        }
    }

    /// loop 动画两轮之间随机暂停
    private func scheduleLoopPause() {
        loopPauseTimer?.invalidate()
        let delay = Double.random(in: loopPauseMin...loopPauseMax)
        loopPauseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // 确保 pause 期间没有被其他动作打断
                guard self.state == .idle else { return }
                self.currentImageName = self.frames.first?.imageName ?? "\(self.state.rawValue)_1"
                self.scheduleNextFrame()
            }
        }
    }

    // ============================================================
    // MARK: - idle 眨眼子系统
    // ============================================================

    /// 安排下一次眨眼（随机 1~3 秒后）
    private func scheduleIdleBlink() {
        idleBlinkTimer?.invalidate()
        let delay = Double.random(in: idleBlinkMinInterval...idleBlinkMaxInterval)
        idleBlinkTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.performIdleBlink()
            }
        }
    }

    /// 执行眨眼：短暂显示 idle_3，再恢复呼吸
    private func performIdleBlink() {
        // 只在 idle 状态且未被打断时执行
        guard state == .idle else { return }

        // 闭眼
        currentImageName = "idle_3"

        // 极短闭眼后睁眼
        idleBlinkTimer?.invalidate()
        idleBlinkTimer = Timer.scheduledTimer(withTimeInterval: idleBlinkDuration, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.state == .idle else { return }
                // 恢复呼吸帧
                self.currentImageName = self.frames.first?.imageName ?? "idle_1"
                // 安排下一次眨眼
                self.scheduleIdleBlink()
            }
        }
    }

    // ============================================================
    // MARK: - 状态切换
    // ============================================================

    /// 切换到新动作并重建帧数组、重置帧索引、启动画时钟
    private func transitionTo(_ newState: HamsterAction) {
        // 离开 idle 时停掉眨眼定时器
        if newState != .idle {
            idleBlinkTimer?.invalidate()
        }

        // 离开 sleep 时停掉唤醒定时器
        if state == .sleep {
            sleepWakeTimer?.invalidate()
            sleepWakeTimer = nil
        }

        // 相同状态不重复切换（除非帧数组为空）
        guard state != newState || frames.isEmpty else { return }

        state = newState
        currentFrameIndex = 0
        buildFrames(for: newState)
        currentImageName = frames.first?.imageName ?? "\(newState.rawValue)_1"
        scheduleNextFrame()

        // 进入 idle 时启动眨眼定时器
        if newState == .idle {
            scheduleIdleBlink()
        }
    }

    // ============================================================
    // ============================================================
    // MARK: - ★ 对外交互接口 ★
    // ============================================================
    // ============================================================

    // ----------------------------------------------------------
    // MARK: triggerClick — 点击仓鼠
    // ----------------------------------------------------------

    /// 点击仓鼠时调用。
    /// - 更新交互时间 & 点击数
    /// - 若正在 sleep/sleepy → 打断回 idle
    /// - 若连续点击 ≥ angryClickThreshold → 触发 angry
    func triggerClick() {
        lastInteractionTime = Date()
        randomizeLazyThreshold()
        resetBoredomTimer()

        // 更新点击窗口 & 计数
        let now = Date()
        if now.timeIntervalSince(clickWindowStart) > clickWindowDuration {
            clickCount = 0
            clickWindowStart = now
        }
        clickCount += 1

        // sleep / sleepy 被点击 → 立即打断回 idle
        if state == .sleep || state == .sleepy {
            isAnimationLocked = false
            transitionTo(.idle)
            return
        }

        // once 动画播放中不可打断（drag 除外，drag 由 triggerDrag 接管）
        if isAnimationLocked && state != .idle {
            return
        }

        // 连续点击过多 → angry
        if clickCount >= angryClickThreshold {
            if !isInCooldown {
                clickCount = 0
                transitionTo(.angry)
                isAnimationLocked = true
                scheduleUnlock(for: .angry)
            }
            return
        }

        // 点击数适中 → 不做动作切换（点击缩放反馈由 View 层处理）
    }

    // ----------------------------------------------------------
    // MARK: wakeFromSleep — 点击睡觉中的仓鼠唤醒
    // ----------------------------------------------------------

    /// 单击睡眠中的仓鼠：取消自动唤醒定时器，播放 sleepy_2 → sleepy_1 → idle 唤醒序列。
    /// 非 sleep 状态下调用无效果。
    func wakeFromSleep() {
        guard state == .sleep else { return }

        lastInteractionTime = Date()
        randomizeLazyThreshold()
        resetBoredomTimer()

        sleepWakeTimer?.invalidate()
        sleepWakeTimer = nil
        isAnimationLocked = false

        playWakeSequence()
    }

    // ----------------------------------------------------------
    // MARK: triggerLongPress — 长按蓄力
    // ----------------------------------------------------------

    /// 鼠标长按 0.2s 后调用，仅播放 drag_1（蓄力）并定格。
    func triggerLongPress() {
        lastInteractionTime = Date()
        randomizeLazyThreshold()
        resetBoredomTimer()
        isDragging = true
        isAnimationLocked = true
        animationTimer?.invalidate()
        state = .drag
        currentFrameIndex = 0
        buildFrames(for: .drag)
        currentImageName = frames.first?.imageName ?? "drag_1"
        // 不调用 scheduleNextFrame，定格在 drag_1
    }

    // ----------------------------------------------------------
    // MARK: triggerDrag — 拖拽
    // ----------------------------------------------------------

    /// 拖拽时调用（drag 动画按阶段顺序播放，不循环）。
    ///
    /// **帧映射（4 帧）：**
    /// ```
    /// [drag_1 蓄力] → [drag_2 悬空] → [drag_3 拖拽]
    /// → [drag_4 复位] → idle
    /// ```
    /// - `.began`：若已在 drag（长按已播 drag_1），从当前帧继续；否则从头播放 drag_1→drag_2→drag_3，到达 drag_3 后定格
    /// - `.changed`：保持在 drag_3，更新位置
    /// - `.ended`：播放 drag_4，播完回 idle
    func triggerDrag(delta: CGPoint, phase: DragPhase) {
        lastInteractionTime = Date()
        randomizeLazyThreshold()

        switch phase {
        case .began:
            // 如果长按已经播了 drag_1，直接从当前帧继续推进
            if state == .drag {
                scheduleNextFrame() // → drag_2→drag_3，定格
                return
            }
            isDragging = true
            isAnimationLocked = true
            resetBoredomTimer()
            animationTimer?.invalidate()
            state = .drag
            currentFrameIndex = 0
            buildFrames(for: .drag)
            currentImageName = frames.first?.imageName ?? "drag_1"
            scheduleNextFrame() // → 自动推进 drag_1→2→3，到 3 冻结

        case .changed:
            guard state == .drag else { return }
            // 仅更新位置，帧定格在 drag_3（高速拖拽带速度线）
            position.x += delta.x
            position.y += delta.y

        case .ended:
            guard state == .drag else { return }
            isDragging = false
            // 从当前帧继续播放释放序列 drag_4
            animationTimer?.invalidate()
            currentFrameIndex = 3 // drag_4: 复位
            currentImageName = frames[3].imageName
            scheduleNextFrame() // → 自动推进到末尾 → onAnimationCycleComplete → idle
        }
    }

    // ----------------------------------------------------------
    // MARK: triggerRefresh — 充值/刷新
    // ----------------------------------------------------------

    /// 充值或额度刷新时调用。
    /// 随机触发 happy 或 surprised（各 50%）。
    func triggerRefresh() {
        lastInteractionTime = Date()
        randomizeLazyThreshold()
        resetBoredomTimer()

        // 打断 sleep
        if state == .sleep || state == .sleepy {
            isAnimationLocked = false
            transitionTo(.idle)
        }

        guard !isInCooldown else { return }
        guard state == .idle else { return }

        let roll = Double.random(in: 0...1)
        let target: HamsterAction = roll < refreshHappyProbability ? .happy : .surprised
        transitionTo(target)
        isAnimationLocked = true
        scheduleUnlock(for: target)
    }

    // ----------------------------------------------------------
    // MARK: updateData — 数据更新（token 消耗）
    // ----------------------------------------------------------

    /// 检测到用户产生 token 消耗（对话/使用）时调用。
    ///
    /// 嗑瓜子机制：
    /// - 每次消耗累计 `usageStreak`（无论当前状态，不打断正在播放的动画）
    /// - 连续消耗达到 `usageStreakThreshold` 次（"几次对话"）且当前空闲 → 触发 eat
    /// - 触发后重置计数，并在 `eatCooldownDuration` 内不再触发（防止一直嗑瓜子）
    func updateData(type: QuotaOrToken) {
        lastInteractionTime = Date()
        randomizeLazyThreshold()
        resetBoredomTimer()

        // 无论状态如何都累计使用
        usageStreak += 1

        // 全局冷却中：只累计，不触发
        guard !isInCooldown else { return }
        // 非 idle：不打断当前 once 动作
        guard state == .idle else { return }
        // 两次嗑瓜子最小间隔：冷却期内清零累计，避免冷却一结束立即连嗑
        guard Date().timeIntervalSince(lastEatTime) >= eatCooldownDuration else {
            usageStreak = 0
            return
        }
        // 连续使用次数未达标
        guard usageStreak >= usageStreakThreshold else { return }

        // 达标 → 嗑瓜子
        usageStreak = 0
        lastEatTime = Date()
        transitionTo(.eat)
        isAnimationLocked = true
        scheduleUnlock(for: .eat)
    }

    // ============================================================
    // ============================================================
    // MARK: - ★ 懒惰探测器（Sleepy / Sleep） ★
    // ============================================================
    // ============================================================

    /// 每 10 秒检查一次：若 idle 超过 lazyThreshold → 触发 sleepy
    private func startLazyDetector() {
        lazyTimer?.invalidate()
        lazyTimer = Timer.scheduledTimer(
            withTimeInterval: 10,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.checkLaziness()
            }
        }
    }

    private func checkLaziness() {
        guard state == .idle else { return }
        guard !isInCooldown else { return }

        let idleTime = Date().timeIntervalSince(lastInteractionTime)
        guard idleTime >= currentLazyThreshold else { return }

        // 触发 sleepy（once 动画，降低帧率）
        transitionTo(.sleepy)
        isAnimationLocked = true

        // sleepy 播完后概率进入 sleep
        let sleepyTotal = totalDuration(of: .sleepy)
        DispatchQueue.main.asyncAfter(deadline: .now() + sleepyTotal) { [weak self] in
            guard let self else { return }
            // 如果用户在 sleepy 期间点击了，会被打断回 idle，state ≠ sleepy
            guard self.state == .sleepy else { return }

            let roll = Double.random(in: 0...1)
            if roll < self.sleepProbability {
                // 进入 sleep（loop 动画，可被点击打断）
                self.transitionTo(.sleep)
                self.isAnimationLocked = false
            } else {
                // 直接回 idle
                self.transitionTo(.idle)
                self.isAnimationLocked = false
                self.setCooldown()
            }
        }
    }

    // ============================================================
    // MARK: - ★ Sleep 唤醒序列 ★
    // ============================================================

    /// sleep_4 定格后启动唤醒定时器，40~60 秒后播放 sleepy_2 → sleepy_1 → idle
    private func startSleepWakeTimer() {
        sleepWakeTimer?.invalidate()
        let delay = Double.random(in: 40...60)
        sleepWakeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.playWakeSequence()
            }
        }
    }

    /// 播放醒来序列：sleepy_2 (~2s) → sleepy_1 (~2s) → idle
    private func playWakeSequence() {
        guard state == .sleep else { return }

        // 1. 显示 sleepy_2
        currentImageName = "sleepy_2"

        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 1...3)) { [weak self] in
            guard let self, self.state == .sleep else { return }

            // 2. 显示 sleepy_1
            self.currentImageName = "sleepy_1"

            DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 1...3)) { [weak self] in
                guard let self, self.state == .sleep else { return }

                // 3. 回到 idle
                self.transitionTo(.idle)
                self.isAnimationLocked = false
                self.setCooldown()
            }
        }
    }

    // ============================================================
    // ============================================================
    // MARK: - ★ 无聊探测器（随机动作） ★
    // ============================================================
    // ============================================================

    /// 每隔 15~40 秒，在 idle 状态时随机触发一个动作
    private func scheduleBoredomAction() {
        boredomTimer?.invalidate()
        let delay = Double.random(in: boredomIntervalMin...boredomIntervalMax)
        boredomTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.triggerBoredom()
            }
        }
    }

    /// 重置无聊计时器 — 用户交互/外部触发后重新倒数
    private func resetBoredomTimer() {
        scheduleBoredomAction()
    }

    private func triggerBoredom() {
        // 多重守卫：idle 状态 + 未锁定 + 未拖拽 + 未冷却 + 未在走路
        guard state == .idle,
              !isAnimationLocked,
              !isDragging,
              !isInCooldown else {
            scheduleBoredomAction() // 当前忙，等下一轮
            return
        }

        let action = boredomActions.randomElement()!
        switch action {
        case .eat, .happy, .surprised:
            transitionTo(action)
            isAnimationLocked = true
            scheduleUnlock(for: action)
        case .sleepy:
            // sleepy 播完后概率进 sleep
            transitionTo(.sleepy)
            isAnimationLocked = true
            let sleepyTotal = totalDuration(of: .sleepy)
            DispatchQueue.main.asyncAfter(deadline: .now() + sleepyTotal) { [weak self] in
                guard let self, self.state == .sleepy else { return }
                if Double.random(in: 0...1) < self.sleepProbability {
                    self.transitionTo(.sleep)
                    self.isAnimationLocked = false
                } else {
                    self.transitionTo(.idle)
                    self.isAnimationLocked = false
                    self.setCooldown()
                }
            }
        default:
            break
        }

        // 播完后安排下一轮
        let actionDuration = totalDuration(of: action) + cooldownDuration * 2
        DispatchQueue.main.asyncAfter(deadline: .now() + actionDuration) { [weak self] in
            self?.scheduleBoredomAction()
        }
    }

    // ============================================================
    // ============================================================
    // MARK: - ★ 冷却与防抖 ★
    // ============================================================
    // ============================================================

    /// 当前是否在冷却中
    private var isInCooldown: Bool {
        Date() < cooldownUntil
    }

    /// 设置冷却标记
    private func setCooldown() {
        cooldownUntil = Date().addingTimeInterval(cooldownDuration)
    }

    /// 安排 once 动画播完后解锁并进入冷却
    private func scheduleUnlock(for action: HamsterAction) {
        let duration = totalDuration(of: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            self.isAnimationLocked = false
            self.setCooldown()
        }
    }

    // ============================================================
    // MARK: - 工具方法
    // ============================================================

    /// 随机化懒惰探测器阈值（每次交互后调用，让 sleepy 触发时间有变化）
    private func randomizeLazyThreshold() {
        currentLazyThreshold = Double.random(in: lazyThresholdMin...lazyThresholdMax)
    }

    /// 跳转到指定帧索引并重建时钟
    private func seekToFrame(_ index: Int) {
        guard index >= 0, index < frames.count else { return }
        currentFrameIndex = index
        currentImageName = frames[currentFrameIndex].imageName
        scheduleNextFrame()
    }

    /// 计算某个动作完整播放一遍的总时长
    /// 直接对 `makeFrames` 的逐帧时长求和 —— 避免帧时长表（如 eat）与
    /// 「基准帧时长 × 帧数」的估算值不一致，导致解锁 / 冷却提前触发。
    private func totalDuration(of action: HamsterAction) -> TimeInterval {
        Self.makeFrames(for: action).reduce(0) { $0 + $1.duration }
    }
}

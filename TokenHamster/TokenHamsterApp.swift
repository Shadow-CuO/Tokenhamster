//
//  TokenHamsterApp.swift
//  TokenHamster
//
//  Created by Oscar Sun on 2026/7/13.
//

import SwiftUI
import AppKit
import QuartzCore

// MARK: - 自定义浮动面板

/// 透明、无边框、置顶、不激活主窗口的面板
final class FloatingPanel: NSPanel {

    /// ★ 是否允许变 key（Dashboard 不需要 key 就能响应点击）
    var allowedToBecomeKey: Bool = true

    /// ★ Dashboard/设置面板是否可拖拽移动
    var movableByBackground: Bool = false {
        didSet { isMovableByWindowBackground = movableByBackground }
    }

    override var canBecomeKey: Bool { allowedToBecomeKey }
    override var canBecomeMain: Bool { false }

    /// ★ 强制永不显示阴影（macOS 会在窗口变 key 时自动加阴影）
    override var hasShadow: Bool {
        get { false }
        set { super.hasShadow = false }
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureWindow()
    }

    private func configureWindow() {
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        super.hasShadow = false
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    /// hasShadow 恒为 false（窗口永不显示阴影），becomeKey/resignKey 无需任何额外操作。
    /// ★ 之前在此调用 invalidateShadow()：即使延迟到 async，窗口 key 状态切换本身
    ///   就会触发 AppKit 对视图树做布局，若再请求阴影失效/重算会叠加布局周期
    ///   → _NSDetectedLayoutRecursion。直接移除，彻底消除该触发源。
    override func becomeKey() {
        super.becomeKey()
    }

    override func resignKey() {
        super.resignKey()
    }

    /// 确保所有 NSHostingView 不显示默认背景 + 禁阴影
    /// ★ 移除对 layer 的一切外部干预：NSHostingView 的 layer 由 SwiftUI 内部管理，
    ///   外部设置 wantsLayer / 修改 layer 属性会触发 hosting layout 系统重新布局 → 布局递归。
    ///   透明背景已由 configureWindow() 的 isOpaque=false + backgroundColor=.clear 保证。
    override var contentView: NSView? {
        didSet {
            // 有意留空 — NSHostingView 默认透明，无需任何 layer 操作
        }
    }
}

// MARK: - 自定义托管视图

/// 处理鼠标拖拽移动窗口 + 右键菜单
private final class ClickthroughHostingView<Content: View>: NSHostingView<Content> {

    weak var stateMachine: HamsterStateMachine?
    /// 右键菜单回调（由 AppDelegate 注入）
    var onRightClick: (() -> Void)?

    private var isDragging = false
    private var mouseDownLocation: CGPoint = .zero
    private var windowOriginAtDragStart: CGPoint = .zero
    private var longPressTimer: Timer?
    private var longPressFired = false

    // MARK: - 拖拽落定回弹（Apple：手势结束 → 弹簧过冲落定，随时可被新拖拽打断）

    /// 最近的拖拽采样（时间 + 屏幕坐标），用于计算松手速度
    private var dragSamples: [(time: TimeInterval, point: CGPoint)] = []
    /// 落定回弹物理时钟
    private var springSettleTimer: Timer?
    /// 弹簧状态（X / Y 独立，Apple §3 分解 2D 运动）
    private struct SpringState {
        var pos: CGFloat
        var vel: CGFloat
    }

    override func mouseDown(with event: NSEvent) {
        // 可中断：再次按下立即停掉尚未完成的落定回弹（Apple §3）
        springSettleTimer?.invalidate()
        springSettleTimer = nil
        dragSamples.removeAll()
        mouseDownLocation = NSEvent.mouseLocation
        windowOriginAtDragStart = window?.frame.origin ?? .zero
        longPressFired = false

        // 长按 0.2 秒后播放 drag_1
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.longPressFired = true
                self.stateMachine?.triggerLongPress()
            }
        }

        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func mouseDragged(with event: NSEvent) {
        longPressTimer?.invalidate()
        longPressTimer = nil

        let currentLocation = NSEvent.mouseLocation
        let dx = abs(currentLocation.x - mouseDownLocation.x)
        let dy = abs(currentLocation.y - mouseDownLocation.y)

        if !isDragging && (dx > 3 || dy > 3) {
            isDragging = true
            if longPressFired {
                // drag_1 已播放，从当前帧继续拖拽
                stateMachine?.triggerDrag(delta: .zero, phase: .began)
            } else {
                // 未长按，直接开始完整拖拽
                stateMachine?.triggerDrag(delta: .zero, phase: .began)
            }
        }

        guard isDragging, let window = self.window else {
            super.mouseDragged(with: event)
            return
        }

        let deltaX = currentLocation.x - mouseDownLocation.x
        let deltaY = currentLocation.y - mouseDownLocation.y
        var frame = window.frame
        frame.origin.x = windowOriginAtDragStart.x + deltaX
        frame.origin.y = windowOriginAtDragStart.y + deltaY
        // ★ display: false — 拖拽时禁止强制同步重绘+布局整个窗口层级，
        //   避免在 SwiftUI hosting view 布局期间触发 layoutSubtreeIfNeeded 递归
        window.setFrame(frame, display: false)

        // 记录速度采样（最多保留最近 6 个）
        let now = ProcessInfo.processInfo.systemUptime
        dragSamples.append((now, currentLocation))
        if dragSamples.count > 6 { dragSamples.removeFirst(dragSamples.count - 6) }

        stateMachine?.triggerDrag(
            delta: CGPoint(x: deltaX, y: deltaY),
            phase: .changed
        )
    }

    override func mouseUp(with event: NSEvent) {
        longPressTimer?.invalidate()
        longPressTimer = nil

        if isDragging {
            isDragging = false
            stateMachine?.triggerDrag(delta: .zero, phase: .ended)
            if let w = window {
                stateMachine?.center = w.frame.origin
            }
            // 落定回弹：以松手瞬间速度（动量）驱动，窗口轻微过冲后弹簧落定
            settleWindowAfterDrag()
        } else if longPressFired {
            // 纯长按（无移动），松手后从 drag_1 回 idle
            longPressFired = false
            stateMachine?.triggerDrag(delta: .zero, phase: .ended)
        }
        super.mouseUp(with: event)
    }

    // MARK: - 拖拽落定回弹

    /// 松手速度（最近采样段的速度，px/s）
    private func releaseVelocity() -> CGPoint {
        guard dragSamples.count >= 2 else { return .zero }
        let first = dragSamples.first!
        let last = dragSamples.last!
        let dt = last.time - first.time
        guard dt > 0.001 else { return .zero }
        return CGPoint(
            x: (last.point.x - first.point.x) / CGFloat(dt),
            y: (last.point.y - first.point.y) / CGFloat(dt)
        )
    }

    /// 落定回弹：Apple §6 动量投影（指数衰减）决定落点（限制短距离）
    /// → 独立 X / Y 弹簧（damping 0.8 轻微过冲，response ≈ 0.35）
    private func settleWindowAfterDrag() {
        guard let window else { return }
        // 减少动态效果 → 直接落定，不播放回弹
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let velocity = releaseVelocity()
        dragSamples.removeAll()

        let start = window.frame.origin

        // Apple 动量投影：project(v) = (v/1000) * d / (1 - d)，d ≈ 0.998
        let d: CGFloat = 0.998
        let maxSettle: CGFloat = 16
        let rawDx = (velocity.x / 1000) * d / (1 - d)
        let rawDy = (velocity.y / 1000) * d / (1 - d)
        let dx = max(-maxSettle, min(maxSettle, rawDx))
        let dy = max(-maxSettle, min(maxSettle, rawDy))
        let target = CGPoint(x: start.x + dx, y: start.y + dy)

        // 几乎不动（慢慢放下）→ 目标 ≈ 起点，无需回弹
        guard hypot(dx, dy) > 0.5 else { return }

        runSettleSpring(from: start, to: target, velocity: velocity)
    }

    /// 弹簧物理积分（半隐式欧拉）：x'' = −ω²(x − target) − 2ζω·x'
    private func runSettleSpring(from start: CGPoint, to target: CGPoint, velocity: CGPoint) {
        springSettleTimer?.invalidate()
        guard let window else { return }

        let omega: CGFloat = 2 * .pi / 0.35   // response ≈ 0.35s
        let zeta: CGFloat = 0.8               // 手势带动量 → 轻微过冲
        let dt: CGFloat = 1.0 / 120.0

        var sx = SpringState(pos: start.x, vel: velocity.x)
        var sy = SpringState(pos: start.y, vel: velocity.y)

        springSettleTimer = Timer.scheduledTimer(withTimeInterval: dt, repeats: true) { [weak self, weak window] _ in
            guard let self, let window else {
                self?.springSettleTimer?.invalidate()
                self?.springSettleTimer = nil
                return
            }
            // 半隐式欧拉积分（X / Y 独立弹簧）
            let ax = -omega * omega * (sx.pos - target.x) - 2 * zeta * omega * sx.vel
            let ay = -omega * omega * (sy.pos - target.y) - 2 * zeta * omega * sy.vel
            sx.vel += ax * dt
            sy.vel += ay * dt
            sx.pos += sx.vel * dt
            sy.pos += sy.vel * dt
            window.setFrameOrigin(CGPoint(x: sx.pos, y: sy.pos))

            // 稳定判定：速度与位移都足够小 → 精确落定
            let speed = hypot(sx.vel, sy.vel)
            let dist = hypot(sx.pos - target.x, sy.pos - target.y)
            if speed < 0.6 && dist < 0.6 {
                self.springSettleTimer?.invalidate()
                self.springSettleTimer = nil
                window.setFrameOrigin(target)
            }
        }
    }
}

// MARK: - Dashboard 顶部拖拽区

/// Dashboard 顶部的拖拽区：在此区域按住直接拖动即可移动窗口（与 macOS 标题栏行为一致）。
/// 仅此区域可移动窗口，其余内容区域不受影响。
final class DashboardDragHandleView: NSView {

    private var isDragging = false
    private var mouseDownLocation: CGPoint = .zero
    private var windowOriginAtDragStart: CGPoint = .zero

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = NSEvent.mouseLocation
        windowOriginAtDragStart = window?.frame.origin ?? .zero
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = self.window else { return }

        let currentLocation = NSEvent.mouseLocation
        if !isDragging {
            let dx = abs(currentLocation.x - mouseDownLocation.x)
            let dy = abs(currentLocation.y - mouseDownLocation.y)
            guard dx > 3 || dy > 3 else { return }
            isDragging = true
        }

        let deltaX = currentLocation.x - mouseDownLocation.x
        let deltaY = currentLocation.y - mouseDownLocation.y
        var frame = window.frame
        frame.origin.x = windowOriginAtDragStart.x + deltaX
        frame.origin.y = windowOriginAtDragStart.y + deltaY
        // display: false — 拖拽时避免强制同步重绘整个窗口层级
        window.setFrame(frame, display: false)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }
}

/// 将 DashboardDragHandleView 桥接给 SwiftUI
struct DashboardDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DashboardDragHandleView {
        DashboardDragHandleView()
    }

    func updateNSView(_ nsView: DashboardDragHandleView, context: Context) {}
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var panel: FloatingPanel?
    private var dashboardPanel: FloatingPanel?
    private let stateMachine = HamsterStateMachine()
    private let dashboardVM = DashboardViewModel()
    /// ★ NSPanel 初始化后自带默认空 contentView（非 nil），
    ///   不能靠 contentView == nil 判断是否已装 Dashboard，
    ///   用显式标记跟踪，避免重复赋值 hosting view 引入布局周期
    private var dashboardHostingViewInstalled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // ★ 最先应用已保存的语言 / 币种偏好 —— 必须早于任何界面构建，
        //   否则首帧会用默认语言（英文）渲染，切完再跳一次。
        _ = AppSettingsStore.shared

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let windowWidth: CGFloat = 200
        let windowHeight: CGFloat = 200
        let windowRect = NSRect(
            x: screenFrame.maxX - windowWidth - 40,
            y: screenFrame.maxY - windowHeight - 60,
            width: windowWidth,
            height: windowHeight
        )

        let panel = FloatingPanel(contentRect: windowRect)
        self.panel = panel

        let contentView = ContentView()
            .environmentObject(stateMachine)
        let hostingView = ClickthroughHostingView(rootView: contentView)
        hostingView.stateMachine = stateMachine
        hostingView.onRightClick = { [weak self] in
            self?.showRightClickMenu()
        }
        panel.contentView = hostingView
        // ★ 延迟 makeKeyAndOrderFront 到下一 run loop，
        //   避免 contentView 赋值触发的布局与 key window 切换叠加
        DispatchQueue.main.async { [weak panel] in
            panel?.makeKeyAndOrderFront(nil)
        }

        // 监听 Dashboard 切换通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(toggleDashboard),
            name: .toggleDashboard,
            object: nil
        )

        // ★ 挂接 DashboardViewModel ↔ 仓鼠状态机联动
        setupDashboardCallbacks()

        // ★ 启动轮询 — 有启用的数据源时立即拉取最新额度并定时刷新（综合监测）
        dashboardVM.startPolling()
    }

    // MARK: - 后端与仓鼠联动

    private func setupDashboardCallbacks() {
        dashboardVM.onDataUpdateSuccess = { [weak self] in
            self?.stateMachine.triggerRefresh()
        }

        dashboardVM.onDataUpdateError = { [weak self] _ in
            self?.stateMachine.triggerClick()
        }

        dashboardVM.onTokenRecharge = { [weak self] in
            self?.stateMachine.triggerRefresh()
        }

        /// ★ 检测到 token 消耗（用户对话使用）→ 累计连续使用，达标后嗑瓜子
        dashboardVM.onTokenUsage = { [weak self] in
            self?.stateMachine.updateData(type: .token)
        }

        /// ★ 设置面板"关闭桌宠" → 退出应用
        dashboardVM.onClosePet = { [weak self] in
            self?.quitApp()
        }
    }

    // MARK: - Dashboard 独立面板

    @objc private func toggleDashboard() {
        // ★ 从 SwiftUI 手势（onTapGesture → NotificationCenter.post）同步调用到这里时，
        //   hosting view 可能正处在其 layout() 中。直接 orderOut/setFrame/orderFront
        //   会与 AppKit 布局互相嵌套 → _NSDetectedLayoutRecursion。
        //   全部延迟到下一 run loop 统一执行。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let dp = self.dashboardPanel, dp.isVisible {
                self.closeDashboardPanel(dp)
            } else {
                self.showDashboardPanel()
            }
        }
    }

    /// 关闭 Dashboard：向仓鼠方向滑动 + 淡出（进入/退出同路径，Apple §7）。
    /// 减少动态效果 → 直接隐藏，不播放动画。
    private func closeDashboardPanel(_ dp: NSPanel) {
        guard let hamsterPanel = panel,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            dp.orderOut(nil)
            return
        }

        let from = dp.frame
        let to = hamsterPanel.frame
        // 面板中心 → 仓鼠中心方向
        let dir = CGVector(dx: to.midX - from.midX, dy: to.midY - from.midY)
        let len = max(hypot(dir.dx, dir.dy), 1)
        let unit = CGVector(dx: dir.dx / len, dy: dir.dy / len)
        // 滑出距离：至少 36pt（间距不足时也保持可见滑出）
        let slideOut = max(len * 0.6, 36)
        let finalOrigin = CGPoint(
            x: from.origin.x + unit.dx * slideOut,
            y: from.origin.y + unit.dy * slideOut
        )

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            dp.animator().setFrameOrigin(finalOrigin)
            dp.animator().alphaValue = 0
        } completionHandler: {
            dp.orderOut(nil)
            // 复位，下次打开为完整不透明
            dp.alphaValue = 1
        }
    }

    private func showDashboardPanel() {
        guard let hamsterPanel = panel else { return }

        let panelWidth: CGFloat = 364
        let panelHeight: CGFloat = 640
        let gap: CGFloat = 12

        let hamsterFrame = hamsterPanel.frame
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // 计算左右可用空间
        let spaceLeft = hamsterFrame.minX - screenFrame.minX
        let spaceRight = screenFrame.maxX - hamsterFrame.maxX

        // 选空间更大的那侧
        let placeOnLeft = spaceLeft >= spaceRight && spaceLeft >= panelWidth + gap

        let dashboardX: CGFloat
        if placeOnLeft {
            dashboardX = hamsterFrame.minX - panelWidth - gap
        } else {
            dashboardX = hamsterFrame.maxX + gap
        }

        // 垂直对齐：dashboard 内容顶部与仓鼠面板顶部对齐
        let dashboardY = hamsterFrame.maxY - panelHeight

        let dashboardRect = NSRect(
            x: dashboardX,
            y: dashboardY,
            width: panelWidth,
            height: panelHeight
        )

        // 复用或创建 Dashboard 面板
        let dp: FloatingPanel
        if let existing = dashboardPanel {
            dp = existing
        } else {
            dp = FloatingPanel(contentRect: dashboardRect)
            dashboardPanel = dp
        }
        dp.allowedToBecomeKey = true  // 设置面板需要接收文本输入
        // ★ 关闭整窗背景拖动 — 改为仅顶部把手长按拖动（见 DashboardDragHandleView）

        // ★ 仅在首次创建时设置 contentView：重复替换会销毁旧 hosting view 并重建，
        //   面板切换时引入额外布局周期 → 增大 layoutSubtreeIfNeeded 递归风险。
        //   同时保留面板内 @State（如是否在设置页）避免每次打开都重置。
        //   注意：NSPanel 的 contentView 初始不为 nil（自带空 NSView），
        //   因此必须用显式标记 dashboardHostingViewInstalled 判断。
        if !dashboardHostingViewInstalled {
            let dashboardView = DashboardView(
                viewModel: dashboardVM,
                onClose: { [weak self] in
                    guard let self, let dp = self.dashboardPanel else { return }
                    self.closeDashboardPanel(dp)
                },
                onSettingsChanged: { [weak self] showing in
                    // ★ onChange 回调在 SwiftUI 视图更新周期内执行，此时 hosting view
                    //   可能正处在其 layout() 中。同步修改 NSPanel 属性 / 触发 key 切换
                    //   会与 hosting view 布局互相嵌套 → _NSDetectedLayoutRecursion。
                    //   全部延迟到下一 run loop 统一执行。
                    DispatchQueue.main.async { [weak self] in
                        guard let dp = self?.dashboardPanel else { return }
                        dp.allowedToBecomeKey = showing
                        if showing {
                            // 先进 key，随后用户点击 TextField 时窗口已是 key，
                            // 不会再次触发 becomeKey 的布局周期
                            dp.makeKey()
                        }
                    }
                }
            )
            .frame(width: panelWidth, height: panelHeight)

            dp.contentView = NSHostingView(rootView: dashboardView)
            dashboardHostingViewInstalled = true
        }

        // ★ 延迟 setFrame + orderFront 到下一 run loop：
        //   contentView 赋值（首次）会立即触发 hosting view 布局，若同周期
        //   同步 setFrame 改变窗口 frame，会与 hosting 布局互相嵌套
        //   → _NSDetectedLayoutRecursion（orderFront 之前已延迟，setFrame 漏了）。
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        dp.alphaValue = reduceMotion ? 1 : 0
        DispatchQueue.main.async { [weak self, weak dp] in
            guard let dp else { return }
            dp.setFrame(dashboardRect, display: false)
            dp.orderFront(nil)
            guard !reduceMotion, let hamsterPanel = self?.panel else { return }
            // 从仓鼠侧轻微滑入 + 淡入（与关闭动画同路径对称，Apple §7）
            let from = dp.frame
            let to = hamsterPanel.frame
            let dir = CGVector(dx: from.midX - to.midX, dy: from.midY - to.midY)
            let len = max(hypot(dir.dx, dir.dy), 1)
            let unit = CGVector(dx: dir.dx / len, dy: dir.dy / len)
            let slideIn: CGFloat = 24
            dp.setFrameOrigin(CGPoint(
                x: from.origin.x - unit.dx * slideIn,
                y: from.origin.y - unit.dy * slideIn
            ))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                dp.animator().setFrameOrigin(from.origin)
                dp.animator().alphaValue = 1
            }
        }
    }

    // MARK: - 右键菜单（由 ClickthroughHostingView.rightMouseDown 触发）

    private func showRightClickMenu() {
        guard let panel, let contentView = panel.contentView else { return }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L("Quit TokenHamster"), action: #selector(quitApp), keyEquivalent: ""))
        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: contentView)
    }

    // MARK: - 退出

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.makeKeyAndOrderFront(nil)
        return true
    }
}

// MARK: - SwiftUI 入口

@main
struct TokenHamsterApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}


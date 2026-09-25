//
//  HamsterView.swift
//  TokenHamster
//
//  Created by 孙亦阳 on 2026/7/13.
//

import SwiftUI
import AppKit

struct HamsterView: View {

    /// 动作状态机（由 AppDelegate 创建，通过 .environmentObject 注入）
    @EnvironmentObject var stateMachine: HamsterStateMachine

    /// 减少动态效果（系统辅助功能设置）— 关闭按压/悬停缩放与落定回弹
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 指针交互状态（按压 / 悬停 / 无）
    @State private var interaction: Interaction = .none
    /// 指针是否停留在仓鼠上（onHover 追踪，用于悬停放大）
    @State private var isHovering = false
    /// 拖拽落定回弹标志（drag → idle 时触发一次 squash）
    @State private var isSettling = false

    /// 仓鼠主体尺寸
    private let hamsterSize: CGFloat = 128
    /// 拖拽判定阈值 — 超过则视为拖动并取消按压反馈（Apple §10 ~10px hysteresis）
    private let dragThreshold: CGFloat = 10

    enum Interaction: Equatable {
        case none
        case hovered
        case pressed
    }

    /// 交互缩放（可中断：新交互直接重算，无需等待动画完成）
    private var baseScale: CGFloat {
        switch interaction {
        case .pressed: return 0.88
        case .hovered: return 1.06
        case .none:    return 1.0
        }
    }

    /// 悬停时轻微上浮（提示"可以点我"）
    private var hoverOffset: CGFloat {
        interaction == .hovered ? -6 : 0
    }

    /// 最终缩放 = 交互缩放 × 落定回弹
    private var scale: CGFloat {
        baseScale * (isSettling ? 0.94 : 1.0)
    }

    var body: some View {
        Group {
            if let nsImage = HamsterView.loadSprite(named: stateMachine.currentImageName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: hamsterSize, height: hamsterSize)
            } else {
                // 占位：素材缺失时不崩溃，显示 🐹 图标
                RoundedRectangle(cornerRadius: 16)
                    .fill(.gray.opacity(0.3))
                    .frame(width: hamsterSize, height: hamsterSize)
                    .overlay {
                        Text("🐹")
                            .font(.largeTitle)
                    }
            }
        }
        // 命中区外扩 ~10px（Apple §10 hit padding），视觉更宽容
        .contentShape(Rectangle().inset(by: -10))
        .scaleEffect(scale)
        .offset(y: hoverOffset)
        // 按压/悬停：临界阻尼、无过冲（普通 UI 交互不带动量）
        .animation(
            reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1.0),
            value: interaction
        )
        // 落定回弹第一段：快速压扁（极短，无感）
        .animation(.easeOut(duration: 0.05), value: isSettling)
        .gesture(interactionGesture)
        .onHover { hovering in
            isHovering = hovering
            // 拖拽中不切换悬停态
            if stateMachine.state != .drag {
                interaction = hovering ? .hovered : .none
            }
        }
        .onChange(of: stateMachine.state) { oldState, newState in
            // 拖拽结束落定 → 播放一次 squash 回弹（手势带动量 → damping 0.6）
            if oldState == .drag && newState == .idle {
                triggerSettleBounce()
            }
        }
    }

    /// 手势：按下即反馈（Apple §1），位移超阈值视为拖拽并取消按压态
    private var interactionGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dist = hypot(value.translation.width, value.translation.height)
                if dist > dragThreshold {
                    // 已判定为拖拽（窗口由 AppKit 层 1:1 移动）→ 取消按压反馈
                    interaction = .none
                } else {
                    interaction = .pressed
                }
            }
            .onEnded { value in
                let dist = hypot(value.translation.width, value.translation.height)
                interaction = isHovering ? .hovered : .none
                // 仅"原地点击"（未拖动、未长按蓄力）视为点击
                guard dist < dragThreshold, stateMachine.state != .drag else { return }
                performTap()
            }
    }

    /// 点击仓鼠：唤醒/交互反馈 + 切换 Dashboard
    private func performTap() {
        if stateMachine.state == .sleep {
            stateMachine.wakeFromSleep()
        } else {
            stateMachine.triggerClick()
        }
        NotificationCenter.default.post(name: .toggleDashboard, object: nil)
    }

    /// 拖拽落定回弹：快速压扁 → 带过冲的 spring 回弹（可被新交互随时打断）
    private func triggerSettleBounce() {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.05)) { isSettling = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) { isSettling = false }
        }
    }
}

// MARK: - 通知名

extension Notification.Name {
    static let toggleDashboard = Notification.Name("ToggleDashboard")
}

// MARK: - 素材加载

extension HamsterView {

    /// 加载精灵图：优先 Asset Catalog，兜底 Sprites/ 目录
    static func loadSprite(named imageName: String) -> NSImage? {
        if let image = NSImage(named: imageName) { return image }
        // 解析 "action_frame" 格式 → Sprites/action/action_frame.png
        let parts = imageName.split(separator: "_", maxSplits: 1)
        guard parts.count == 2,
              let baseURL = Bundle.main.resourceURL?
                .appendingPathComponent("Sprites")
                .appendingPathComponent(String(parts[0])) else { return nil }
        let fileURL = baseURL.appendingPathComponent("\(imageName).png")
        return NSImage(contentsOf: fileURL)
    }
}

#Preview {
    HamsterView()
        .environmentObject(HamsterStateMachine())
        .padding()
        .background(Color.black.opacity(0.3))
}

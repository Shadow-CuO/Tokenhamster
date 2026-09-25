//
//  HamsterEatTimingTests.swift
//  TokenHamsterTests
//
//  eat（嗑瓜子）帧序列与时长验收
//  期望序列：eat_1 → 2 3 2 3 4 5 4 5 → eat_6
//    eat_1      : 0.5~0.8s（起势）
//    eat_2..5   : 0.05~0.1s（高频咀嚼）
//    eat_6      : 0.5~0.8s（收势）
//

import Foundation
import Testing
@testable import TokenHamster

@MainActor
struct HamsterEatTimingTests {

    private var frames: [Frame] { HamsterStateMachine.makeFrames(for: .eat) }

    /// 图片序列必须严格是新版编排（含 2 3 2 3 / 4 5 4 5 两轮往复）
    @Test func eatFrameSequenceMatchesDesign() {
        #expect(frames.map(\.imageName) == [
            "eat_1",
            "eat_2", "eat_3", "eat_2", "eat_3",
            "eat_4", "eat_5", "eat_4", "eat_5",
            "eat_6",
        ])
    }

    /// 咀嚼帧（第 2~9 帧）必须落在 0.05~0.1s —— 这是"快速咀嚼"的硬指标
    @Test func chewFramesAreFast() {
        let chews = frames.dropFirst().dropLast()
        #expect(chews.count == 8)
        for frame in chews {
            #expect(frame.duration >= 0.05, "\(frame.imageName) 时长 \(frame.duration) 短于 0.05s")
            #expect(frame.duration <= 0.10, "\(frame.imageName) 时长 \(frame.duration) 长于 0.10s")
        }
    }

    /// 起势 / 收势必须是 0.5~0.8s 的定格，两端读得清
    @Test func headAndTailFramesHold() {
        for frame in [frames.first!, frames.last!] {
            #expect(frame.duration >= 0.5, "\(frame.imageName) 时长 \(frame.duration) 短于 0.5s")
            #expect(frame.duration <= 0.8, "\(frame.imageName) 时长 \(frame.duration) 长于 0.8s")
        }
    }

    /// 咀嚼逐步加速（时长单调不增）—— 避免匀速播放的机械感
    @Test func chewAccelerates() {
        let durations = frames.dropFirst().dropLast().map(\.duration)
        for (previous, next) in zip(durations, durations.dropFirst()) {
            #expect(next <= previous, "咀嚼应逐帧加快，\(previous) → \(next) 变慢了")
        }
        // 首尾必须真有速度差，否则"加速"名不副实
        #expect(durations.last! < durations.first!)
    }

    /// 整段时长 = 0.6 + 0.56 + 0.6 = 1.76s（totalDuration 必须与逐帧求和一致）
    @Test func totalDurationMatchesSumOfFrames() {
        let sum = frames.reduce(0) { $0 + $1.duration }
        #expect(abs(sum - 1.76) < 0.001)
    }

    /// 其它动作仍走基础帧表，不应被 eat 的特例逻辑污染
    @Test func otherActionsUnaffected() {
        let idle = HamsterStateMachine.makeFrames(for: .idle)
        #expect(idle.map(\.imageName) == ["idle_1", "idle_2"])
        let happy = HamsterStateMachine.makeFrames(for: .happy)
        #expect(happy.map(\.imageName) == ["happy_1", "happy_2", "happy_3", "happy_4"])
    }
}

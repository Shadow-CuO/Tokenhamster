//
//  CompactCountFormattingTests.swift
//  TokenHamsterTests
//
//  统一计数规范：1K / 1M / 1B / 1T（英文后缀，不随界面语言翻译）。
//

import Foundation
import Testing
@testable import TokenHamster

struct CompactCountFormattingTests {

    // MARK: - 档位与小数位

    /// 不足 1000 → 整数原样（不带后缀）
    @Test func belowOneThousandShowsPlainInteger() {
        #expect(formatCompactCount(0) == "0")
        #expect(formatCompactCount(1) == "1")
        #expect(formatCompactCount(999) == "999")
        #expect(formatCompactCount(100) == "100")
    }

    /// 恰好到档位 → 后缀不带小数（`.0` 必须去掉）
    @Test func exactThresholdsDropTrailingZero() {
        #expect(formatCompactCount(1_000) == "1K")
        #expect(formatCompactCount(1_000_000) == "1M")
        #expect(formatCompactCount(1_000_000_000) == "1B")
        #expect(formatCompactCount(1_000_000_000_000) == "1T")
        #expect(formatCompactCount(2_000_000_000) == "2B")
        // 不能出现 "1.0K" 这类拖尾
        #expect(!formatCompactCount(1_000).contains(".0"))
    }

    /// 固定 1 位小数，末尾 `.0` 之外都保留
    @Test func nonZeroDecimalIsKept() {
        #expect(formatCompactCount(1_500) == "1.5K")
        #expect(formatCompactCount(12_345) == "12.3K")
        #expect(formatCompactCount(136_300) == "136.3K")
        #expect(formatCompactCount(843_200_000) == "843.2M")
        #expect(formatCompactCount(4_100_000_000) == "4.1B")
        #expect(formatCompactCount(1_100) == "1.1K")
    }

    /// 整数倍量级（如 10_000）同样不带小数
    @Test func wholeNumberScalesDropDecimal() {
        #expect(formatCompactCount(10_000) == "10K")
        #expect(formatCompactCount(500_000) == "500K")
        #expect(formatCompactCount(30_000_000) == "30M")
    }

    // MARK: - 进位（避免 1000K / 1000.0M）

    /// 四舍五入后够得着下一档 → 进位，而不是显示 1000K
    @Test func roundsUpToNextUnitInsteadOfThousand() {
        #expect(formatCompactCount(999_999) == "1M")
        #expect(formatCompactCount(999_999_999) == "1B")
        #expect(formatCompactCount(999_999_999_999) == "1T")
        #expect(!formatCompactCount(999_999).contains("1000"))
    }

    /// 刚好差一点 → 留在本档，不提前进位
    @Test func staysInUnitJustBelowRoundingBoundary() {
        #expect(formatCompactCount(999_949) == "999.9K")
        #expect(formatCompactCount(999_400) == "999.4K")
    }

    // MARK: - 非正常输入

    /// 非有限值不该崩，也不该输出 "nan"/"inf"
    @Test func nonFiniteInputIsSafe() {
        #expect(formatCompactCount(.nan) == "0")
        #expect(formatCompactCount(.infinity) == "0")
        #expect(formatCompactCount(-.infinity) == "0")
    }

    /// Int 便捷入口与主格式化器等价
    @Test func intConvenienceMatchesFormatter() {
        #expect(999.formattedTokenCount == "999")
        #expect(1_000.formattedTokenCount == "1K")
        #expect(1_500.formattedTokenCount == "1.5K")
        #expect(843_200_000.formattedTokenCount == "843.2M")
        #expect(4_100_000_000.formattedTokenCount == "4.1B")
        #expect(Int(1_000_000_000_000).formattedTokenCount == "1T")
    }

    /// ★ 后缀必须与界面语言无关（中文界面同样是 "1.2B"，不是「12 亿」）
    @Test func suffixIsNotLocalized() {
        for language in [AppLanguage.chinese, AppLanguage.english] {
            let text = Localization.t("%@ tokens total", ["1.2B"], language: language)
            #expect(text.contains("1.2B"), "\(language) 下后缀被本地化了：\(text)")
        }
    }

    // MARK: - 防回归：不允许再出现散落的量级格式化
    /// ★★ 曾经有 5 份各不相同的实现（峰值那份 K 用 0 位小数 → "843K"，
    ///    模型行是 "1.0K"）。除 `DataModels.swift` 里的唯一实现外，
    ///    任何文件都不得再写 `String(format: "%.1fK/M/B/T", …)`。
    @Test func noScatteredMagnitudeFormatting() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let appDir = root.appendingPathComponent("TokenHamster", isDirectory: true)
        let regex = try NSRegularExpression(pattern: #"String\(format: "%\.\d+[KMBT]""#)

        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: appDir, includingPropertiesForKeys: nil)
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n").enumerated() {
                let s = String(line)
                // 注释里举例说明正确写法是允许的
                guard !s.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                let range = NSRange(s.startIndex..., in: s)
                if regex.firstMatch(in: s, range: range) != nil {
                    offenders.append("\(file.lastPathComponent):\(index + 1) \(s.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(offenders.isEmpty,
                "发现散落的量级格式化，请改用 formatCompactCount / formattedTokenCount：\(offenders)")
    }
}

// ============================================================
// MARK: - TOTAL TOKENS 头部大字（≤10 位原样，超出后用 K 起步）
// ============================================================

struct TotalTokensHeaderFormattingTests {

    /// 位数 ≤ 10 → 原样显示（**不压缩**）
    @Test func upToTenDigitsShowsExactNumber() {
        #expect(formatTotalTokensDisplay(0) == "0")
        #expect(formatTotalTokensDisplay(1) == "1")
        #expect(formatTotalTokensDisplay(999) == "999")
        #expect(formatTotalTokensDisplay(1_234_567) == 1_234_567.formatted())
        // 10 位是原样显示的上限（本例 = 99.9 亿）
        #expect(formatTotalTokensDisplay(9_999_999_999) == 9_999_999_999.formatted())
    }

    /// 第 11 位起才切换 —— 边界两侧必须一边原样、一边压缩
    @Test func switchHappensAtElevenDigits() {
        let tenDigits = 9_999_999_999
        let elevenDigits = 10_000_000_000
        #expect(formatTotalTokensDisplay(tenDigits) == tenDigits.formatted())
        #expect(formatTotalTokensDisplay(elevenDigits) == "10000000K")
    }

    /// ★ 超出后**优先留在 K**，不急着升 M/B/T
    @Test func prefersKeeingKilounit() {
        // 1.2e10（11 位）→ K 乘数 12,345,679（8 位）
        #expect(formatTotalTokensDisplay(12_345_678_901) == "12345679K")
        // 1.2e12（13 位）→ K 乘数正好 10 位，仍留在 K
        #expect(formatTotalTokensDisplay(1_234_567_890_123) == "1234567890K")
    }

    /// K 乘数会超过 10 位（≥ 10^13）→ 才升档
    @Test func escalatesOnlyWhenKiloMultiplierTooLong() {
        // 1.2e13（14 位）→ K 乘数 12,345,678,901（11 位）超限 → 升 M
        #expect(formatTotalTokensDisplay(12_345_678_901_234) == "12345679M")
        // 1e16（17 位）→ K 14 位、M 11 位都超限 → 升 B
        #expect(formatTotalTokensDisplay(10_000_000_000_000_000) == "10000000B")
    }

    /// ★ 四舍五入进位后位数超限 → 也要升档（K 乘数 9,999,999,999.99… 会变成 10^10）
    @Test func roundingCarryAlsoTriggersEscalation() {
        #expect(formatTotalTokensDisplay(9_999_999_999_999) == "10000000M")
    }

    /// 乘数取整、不带小数（与通用规范不同 —— 头部不显示 "1.2K" 这种）
    @Test func multiplierHasNoDecimalPoint() {
        #expect(!formatTotalTokensDisplay(12_345_678_901).contains("."))
        #expect(!formatTotalTokensDisplay(1_234_567_890_123).contains("."))
    }

    /// 乘数位数永不超过 10（含极大值，不越界也不崩）
    @Test func multiplierNeverExceedsDigitCap() {
        let values: [Int] = [10_000_000_000, 12_345_678_901, 1_234_567_890_123,
                             12_345_678_901_234, 10_000_000_000_000_000, Int.max]
        for value in values {
            let text = formatTotalTokensDisplay(value)
            let digits = text.filter(\.isNumber)
            #expect(digits.count <= 10, "\(value) → \(text) 乘数位数超限")
            #expect(!text.contains("e"), "\(value) → \(text) 出现科学计数法")
        }
        // Int.max（19 位）：K 16 位 / M 13 位超限 → B
        #expect(formatTotalTokensDisplay(Int.max) == "9223372037B")
    }

    /// 负数 / 零不该崩（totalTokens 理论上非负，兜底而已）
    @Test func nonPositiveValuesAreSafe() {
        #expect(formatTotalTokensDisplay(0) == "0")
        #expect(formatTotalTokensDisplay(-1) == "0")
    }

    /// 只有真的超过 10 位才会带上单位后缀
    @Test func suffixAppearsOnlyAfterThreshold() {
        let suffixCharacters = CharacterSet(charactersIn: "KMBT")
        for value in [0, 123, 9_999_999_999] {
            let text = formatTotalTokensDisplay(value)
            #expect(text.rangeOfCharacter(from: suffixCharacters) == nil,
                    "\(value) 不该出现单位后缀：\(text)")
        }
        for value in [10_000_000_000, 12_345_678_901_234] {
            let text = formatTotalTokensDisplay(value)
            #expect(text.rangeOfCharacter(from: suffixCharacters) != nil,
                    "\(value) 应该带单位后缀：\(text)")
        }
    }
}

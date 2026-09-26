//
//  WidgetBridgeTests.swift
//  TokenHamsterTests
//
//  App → 小组件 载荷（WidgetBridge）单元测试。
//
//  ★★ 其中 `payloadJSONKeyContract` 是**跨 target 契约测试**：
//    Widget 侧 `TokenHamsterWidget/WidgetPayloadModels.swift` 是这份模型的镜像副本
//    （Widget 拿不到 App 源码）。改了字段却忘了同步镜像时，这个测试会红。
//

import Foundation
import Testing
@testable import TokenHamster

@MainActor
struct WidgetPayloadBuilderTests {

    /// mock 测试标准防护：防止响应被 URLSession 写进真实缓存目录
    init() { disableURLCacheForMockTests() }

    // ---- 工具 ----

    private func snapshot(
        id: String = "s1",
        name: String = "Codex",
        assetName: String? = "codex",
        status: AgentSourceStatus = .ok,
        windows: [QuotaWindow] = []
    ) -> AgentSnapshot {
        AgentSnapshot(
            id: id, name: name, iconName: "terminal.fill", assetName: assetName,
            sourceType: .local,
            quotaWindows: windows,
            status: status
        )
    }

    private func window(
        _ kind: QuotaWindowKind,
        used: Double,
        resetsAt: Date? = nil
    ) -> QuotaWindow {
        QuotaWindow(kind: kind, usedPercent: used, resetsAt: resetsAt)
    }

    /// 编解码器必须与生产端一致
    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    // ---- 过滤 ----

    /// 已停用（.stale）的源不进小组件
    @Test func dropsStaleSnapshots() {
        let payload = WidgetPayloadBuilder.build(from: [
            snapshot(id: "a", status: .ok, windows: [window(.cycle, used: 10)]),
            snapshot(id: "b", status: .stale, windows: [window(.cycle, used: 20)]),
        ])
        #expect(payload.providers.map(\.id) == ["a"])
    }

    /// 没有额度窗口的源（余额型 API / DSH / Copilot）不进小组件
    @Test func dropsSnapshotsWithoutWindows() {
        let payload = WidgetPayloadBuilder.build(from: [
            snapshot(id: "balance", windows: []),
            snapshot(id: "quota", windows: [window(.session5h, used: 5)]),
        ])
        #expect(payload.providers.map(\.id) == ["quota"])
    }

    /// 拉取失败的源**保留**（带上次成功窗口）→ 小组件显示「更新失败 + 旧数据置灰」
    @Test func keepsErrorSnapshotWithLastKnownWindows() throws {
        let payload = WidgetPayloadBuilder.build(from: [
            snapshot(id: "err", status: .error, windows: [window(.cycle, used: 42)]),
        ])
        let provider = try #require(payload.providers.first)
        #expect(provider.status == "error")
        #expect(provider.windows.count == 1)
        #expect(payload.providers.count == 1)
    }

    // ---- 窗口 ----

    /// 5h 窗口排在周期窗口前面（参考图行序），与输入顺序无关
    @Test func ordersSessionBeforeCycle() {
        let payload = WidgetPayloadBuilder.build(from: [
            snapshot(windows: [
                window(.cycle, used: 19),
                window(.session5h, used: 99),
            ]),
        ])
        #expect(payload.providers.first?.windows.map(\.kind) == ["session5h", "cycle"])
    }

    /// 最多两行 —— 多出来的窗口被截断
    @Test func capsAtTwoWindows() {
        let payload = WidgetPayloadBuilder.build(from: [
            snapshot(windows: [
                window(.cycle, used: 1),
                window(.session5h, used: 2),
                window(.cycle, used: 3),
            ]),
        ])
        #expect(payload.providers.first?.windows.count == 2)
    }

    /// 百分比越界会被夹到 0…100
    @Test func clampsUsedPercent() throws {
        let payload = WidgetPayloadBuilder.build(from: [
            snapshot(windows: [
                window(.session5h, used: -5),
                window(.cycle, used: 120),
            ]),
        ])
        let windows = try #require(payload.providers.first?.windows)
        #expect(windows.first?.usedPercent == 0)
        #expect(windows.last?.usedPercent == 100)
    }

    /// 没有重置时刻的窗口保留 nil（小组件据此省略时间行）
    @Test func keepsNilResetsAt() throws {
        let payload = WidgetPayloadBuilder.build(from: [
            snapshot(windows: [window(.cycle, used: 10, resetsAt: nil)]),
        ])
        let w = try #require(payload.providers.first?.windows.first)
        #expect(w.resetsAt == nil)
    }

    /// 重置时刻原样透传
    @Test func carriesResetsAt() throws {
        let resets = Date(timeIntervalSince1970: 1_800_003_600)
        let payload = WidgetPayloadBuilder.build(from: [
            snapshot(windows: [window(.cycle, used: 10, resetsAt: resets)]),
        ])
        let w = try #require(payload.providers.first?.windows.first)
        #expect(w.resetsAt == resets)
    }

    // ---- 载荷元信息 ----

    @Test func setsVersionAndTimestamp() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = WidgetPayloadBuilder.build(from: [], now: now)
        #expect(payload.version == WidgetQuotaPayload.currentVersion)
        #expect(payload.updatedAt == now)
        #expect(payload.providers.isEmpty)
    }

    // ---- ★★ 跨 target JSON 键契约 ----

    /// 冻结 JSON 键名与编码策略。
    /// ⚠️ Widget 侧镜像模型（`TokenHamsterWidget/WidgetPayloadModels.swift`）依赖这套键，
    ///   改了这里必须同步改镜像，否则 Widget 解码静默失败（只显示空态）。
    @Test func payloadJSONKeyContract() throws {
        let payload = WidgetQuotaPayload(
            version: WidgetQuotaPayload.currentVersion,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            providers: [
                WidgetQuotaProvider(
                    id: "p1", name: "Codex", assetName: "codex",
                    symbolName: "terminal.fill", status: "ok",
                    windows: [
                        WidgetQuotaWindow(
                            kind: "session5h", usedPercent: 99,
                            resetsAt: Date(timeIntervalSince1970: 1_800_003_600)
                        ),
                    ]
                ),
            ]
        )
        let object = try JSONSerialization.jsonObject(with: encoder().encode(payload))
        let root = try #require(object as? [String: Any])

        #expect(Set(root.keys) == ["version", "updatedAt", "providers"])
        // ★ 日期必须是数字时间戳（不是 ISO 字符串）
        #expect(root["updatedAt"] as? Double == 1_800_000_000)

        let providers = try #require(root["providers"] as? [[String: Any]])
        let provider = try #require(providers.first)
        #expect(Set(provider.keys) == ["id", "name", "assetName", "symbolName", "status", "windows"])

        let windows = try #require(provider["windows"] as? [[String: Any]])
        let windowJSON = try #require(windows.first)
        #expect(Set(windowJSON.keys) == ["kind", "usedPercent", "resetsAt"])
        #expect(windowJSON["kind"] as? String == "session5h")
        #expect(windowJSON["resetsAt"] as? Double == 1_800_003_600)
    }

    /// 可选字段为 nil 时键被省略（Widget 侧必须用 decodeIfPresent 解码）
    @Test func payloadOmitsNilOptionals() throws {
        let payload = WidgetQuotaPayload(
            version: WidgetQuotaPayload.currentVersion,
            updatedAt: Date(timeIntervalSince1970: 0),
            providers: [
                WidgetQuotaProvider(
                    id: "p1", name: "X", assetName: nil,
                    symbolName: "terminal.fill", status: "ok",
                    windows: [WidgetQuotaWindow(kind: "cycle", usedPercent: 1, resetsAt: nil)]
                ),
            ]
        )
        let object = try JSONSerialization.jsonObject(with: encoder().encode(payload))
        let root = try #require(object as? [String: Any])
        let provider = try #require((root["providers"] as? [[String: Any]])?.first)
        #expect(provider["assetName"] == nil)
        let windowJSON = try #require((provider["windows"] as? [[String: Any]])?.first)
        #expect(windowJSON["resetsAt"] == nil)
    }

    // ---- 存储 ----

    /// 写入临时目录后能原样解回来（widget 侧读的就是同一个文件）
    @Test func storeRoundTripsPayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.widgetbridge.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = WidgetPayloadBuilder.build(
            from: [
                snapshot(
                    id: "codex", name: "Codex",
                    windows: [
                        window(.session5h, used: 99, resetsAt: Date(timeIntervalSince1970: 1_800_003_600)),
                        window(.cycle, used: 19),
                    ]
                ),
            ],
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        WidgetSnapshotStore.write(payload, to: directory, reloadTimelines: false)

        // ① 文件名固定（widget 侧靠这个名字找）
        let file = directory.appendingPathComponent("WidgetQuota.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        // ② 内容可原样解回（日期策略一致）
        let data = try Data(contentsOf: file)
        #expect(try decoder().decode(WidgetQuotaPayload.self, from: data) == payload)
    }

    /// 语言偏好写成独立文本文件（widget 靠它决定中文/英文）
    @Test func writesLanguageFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.widgetbridge.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        WidgetSnapshotStore.writeLanguage("zh-Hans", to: directory)

        let text = try String(
            contentsOf: directory.appendingPathComponent("WidgetLanguage.txt"), encoding: .utf8
        )
        #expect(text == "zh-Hans")
    }

    // ---- 真实数据源 → 载荷（纯函数，不走网络） ----

    /// Cursor 快照 → 载荷：只有周期窗口（Cursor 无 5h 档）、品牌图取自 spec、百分比=请求数占比。
    /// ★ 用 `CursorSource.buildSnapshot`（纯函数）而不是起 mock server ——
    ///   并发跑测试时本地 socket 偶发失败会让这类断言无故飘红。
    @Test func cursorSnapshotMapsIntoPayload() throws {
        let cycleStart = Date(timeIntervalSince1970: 1_788_000_000)
        let quota = CursorQuotaFetcher.makeSnapshot(CursorUsage(
            models: [CursorModelUsage(modelName: "auto", requests: 45, maxRequests: 100)],
            cycleStart: cycleStart
        ))
        let snap = CursorSource.buildSnapshot(
            id: "cursor-1", name: "Cursor Work", iconName: "cursorarrow.rays",
            assetName: "cursor", quota: quota
        )

        let payload = WidgetPayloadBuilder.build(from: [snap])
        let provider = try #require(payload.providers.first)
        #expect(provider.id == "cursor-1")
        #expect(provider.name == "Cursor Work")
        #expect(provider.assetName == "cursor")
        #expect(provider.status == "ok")
        // 只有一个周期窗口（无 5h），且重置时刻 = 周期起点 + 1 个月
        #expect(provider.windows.count == 1)
        let window = try #require(provider.windows.first)
        #expect(window.kind == "cycle")
        #expect(window.usedPercent == 45)
        #expect(window.resetsAt == Calendar.current.date(byAdding: .month, value: 1, to: cycleStart))
    }

    // ---- 接线 ----

    /// 刷新收尾（`performRefresh`）会把载荷写进注入的目录；
    /// 全空/全停用的**早退分支**也写（小组件据此回到空态，而不是留着过期数据）。
    ///
    /// ★ 本测试只断言「写了 / 写空了」，**不断言抓取到的具体数值** ——
    ///   数值映射由上面的纯函数测试覆盖，抓取链路本身另有 mock 测试。
    @Test func refreshWritesWidgetPayload() async throws {
        let server = try MockHTTPServer(handlers: [
            "/api/usage": { _ in """
            {"startOfMonth": "2026-09-01T00:00:00Z",
             "claude-4-sonnet": {"numRequests": 45, "maxRequestUsage": 100}}
            """ },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        let suiteName = "test.widgetbridge.\(UUID().uuidString)"
        let testDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { testDefaults.removePersistentDomain(forName: suiteName) }
        let widgetDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.widgetwire.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: widgetDirectory) }
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.widgetbridge.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let vm = DashboardViewModel(
            userDefaults: testDefaults, storage: FileAppStorage(directory: tmpDir)
        )
        vm.widgetDirectory = widgetDirectory

        // 第一次刷新：写入载荷（可能因抓取失败而是 error 状态，但文件必须已写入）
        vm.apiConfigs = [APIConfigItem(
            name: "Cursor Mock",
            baseURL: server.baseURL,
            apiKey: "user_abc::jwt-token",
            apiType: .localLog,
            isActive: true,
            agentProvider: .cursor
        )]
        try await vm.manualRefresh()

        let file = widgetDirectory.appendingPathComponent("WidgetQuota.json")
        let payload = try decoder().decode(
            WidgetQuotaPayload.self, from: try Data(contentsOf: file)
        )
        #expect(payload.version == WidgetQuotaPayload.currentVersion)

        // 空源分支：删掉配置后刷新 → 载荷被重写为空（小组件回空态）
        vm.apiConfigs = []
        try await vm.manualRefresh()
        let emptyPayload = try decoder().decode(
            WidgetQuotaPayload.self, from: try Data(contentsOf: file)
        )
        #expect(emptyPayload.providers.isEmpty)
    }
}

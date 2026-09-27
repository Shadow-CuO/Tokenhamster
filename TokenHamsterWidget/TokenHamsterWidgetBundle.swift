//
//  TokenHamsterWidgetBundle.swift
//  TokenHamsterWidget
//
//  Created by Oscar Sun on 2026/7/13.
//

import WidgetKit
import SwiftUI

@main
struct TokenHamsterWidgetBundle: WidgetBundle {
    var body: some Widget {
        // 单源：一个数据源的 5h + 周额度（小尺寸 / 中尺寸）
        SingleProviderQuotaWidget()
        // 双拼：两个数据源并排（中尺寸）
        DualProviderQuotaWidget()
    }
}

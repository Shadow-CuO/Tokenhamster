//
//  ContentView.swift
//  TokenHamster
//
//  Created by Oscar Sun on 2026/7/13.
//

import SwiftUI

struct ContentView: View {

    var body: some View {
        ZStack {
            // 全屏透明背景 — 让窗口透明区域可被鼠标穿透
            Color.clear
                .ignoresSafeArea()

            // 仓鼠桌宠 — 居中偏上
            HamsterView()
                .padding(.top, 40)
        }
        .frame(width: 200, height: 200)
    }
}

#Preview {
    ContentView()
        .background(Color.black.opacity(0.3))
}


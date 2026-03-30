//
//  EmuFleetApp.swift
//  EmuFleet
//
//  Created by Ngonidzashe  Mangudya on 2026/03/30.
//

import SwiftUI

@main
struct EmuFleetApp: App {
    @StateObject private var store = AVDStore()

    var body: some Scene {
        MenuBarExtra("EmuFleet", systemImage: store.hasRunningAVD ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3") {
            MenuBarContentView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Window("AVD Manager", id: "manager") {
            AVDManagerWindowView()
                .environmentObject(store)
        }
        .defaultSize(width: 980, height: 720)
    }
}

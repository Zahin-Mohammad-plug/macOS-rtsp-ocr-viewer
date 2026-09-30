//
//  SharpStreamApp.swift
//  SharpStream
//
//  Created on macOS 14.0+
//

import SwiftUI

@main
struct SharpStreamApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(appState)
                .environmentObject(appState.streamManager)
        }
        .defaultSize(width: 1200, height: 780)
        .windowResizability(.contentMinSize)
        // Always show the player at launch, even if restored window state has
        // no windows (otherwise the app could start with nothing on screen).
        .defaultLaunchBehavior(.presented)
        .commands {
            AppMenu(appState: appState)
        }

        Window("Statistics", id: "statistics") {
            StatisticsWindowView()
                .environmentObject(appState)
                .environmentObject(appState.streamManager)
        }
        .defaultSize(width: 420, height: 680)
        .windowResizability(.contentMinSize)

        Settings {
            PreferencesView()
                .environmentObject(appState)
        }
    }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case error(String)
}

//
//  Sharp_StreamApp.swift
//  Sharp Stream
//
//  Created by Zahin M on 2026-01-20.
//

import SwiftUI
import CoreData

@main
struct Sharp_StreamApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

//
//  KeyboardShortcuts.swift
//  SharpStream
//
//  Global hotkey handling
//

import Foundation
import AppKit
import Combine

class KeyboardShortcuts: ObservableObject {
    @Published var shortcuts: [Shortcut] = []
    
    private var eventMonitor: Any?
    
    struct Shortcut: Identifiable, Codable {
        let id: UUID
        var action: String
        var key: String
        var modifiers: [String]
        
        init(id: UUID = UUID(), action: String, key: String, modifiers: [String] = []) {
            self.id = id
            self.action = action
            self.key = key
            self.modifiers = modifiers
        }
    }
    
    init() {
        loadDefaultShortcuts()
    }
    
    private func loadDefaultShortcuts() {
        shortcuts = [
            Shortcut(action: "playPause", key: "space", modifiers: []),
            Shortcut(action: "rewind10s", key: "left", modifiers: ["command"]),
            Shortcut(action: "forward10s", key: "right", modifiers: ["command"]),
            Shortcut(action: "decreaseSpeed", key: "-", modifiers: ["command"]),
            Shortcut(action: "increaseSpeed", key: "=", modifiers: ["command"]),
            Shortcut(action: "smartPause", key: "s", modifiers: ["command"]),
            Shortcut(action: "frameBackward", key: "left", modifiers: []),
            Shortcut(action: "frameForward", key: "right", modifiers: []),
        ]
    }
    
    func registerGlobalShortcuts() {
        // Global hotkey registration requires accessibility permissions
        // This is a placeholder - would need to use Carbon/Cocoa event handling
    }
    
    func handleKeyPress(_ key: String, modifiers: [String]) -> String? {
        // Find matching shortcut
        for shortcut in shortcuts {
            if shortcut.key == key && Set(shortcut.modifiers) == Set(modifiers) {
                return shortcut.action
            }
        }
        return nil
    }
}

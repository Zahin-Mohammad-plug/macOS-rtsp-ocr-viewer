//
//  ControlsView.swift
//  SharpStream
//
//  Play/pause/scrub/speed controls
//

import SwiftUI

struct ControlsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var playbackSpeed: Double = 1.0
    @State private var volume: Double = 1.0
    
    var body: some View {
        VStack(spacing: 12) {
            // Timeline scrubber
            Slider(value: $currentTime, in: 0...max(duration, 1)) {
                Text("Timeline")
            } minimumValueLabel: {
                Text(formatTime(0))
            } maximumValueLabel: {
                Text(formatTime(duration))
            }
            .onChange(of: currentTime) { newValue in
                seek(to: newValue)
            }
            
            HStack {
                // Play/Pause
                Button(action: togglePlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 30, height: 30)
                }
                .keyboardShortcut(.space, modifiers: [])
                
                // Rewind 10s
                Button(action: { seek(offset: -10) }) {
                    Image(systemName: "gobackward.10")
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                
                // Forward 10s
                Button(action: { seek(offset: 10) }) {
                    Image(systemName: "goforward.10")
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                
                Spacer()
                
                // Frame backward
                Button(action: { stepFrame(backward: true) }) {
                    Image(systemName: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                
                // Frame forward
                Button(action: { stepFrame(backward: false) }) {
                    Image(systemName: "chevron.right")
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                
                Spacer()
                
                // Smart Pause
                Button("Smart Pause") {
                    performSmartPause()
                }
                .keyboardShortcut("s", modifiers: [.command])
                
                Spacer()
                
                // Speed control
                HStack {
                    Text("Speed:")
                    Picker("", selection: $playbackSpeed) {
                        Text("0.25x").tag(0.25)
                        Text("0.5x").tag(0.5)
                        Text("1x").tag(1.0)
                        Text("1.5x").tag(1.5)
                        Text("2x").tag(2.0)
                    }
                    .frame(width: 80)
                    .onChange(of: playbackSpeed) { newValue in
                        setPlaybackSpeed(newValue)
                    }
                }
                
                // Volume control
                HStack {
                    Image(systemName: "speaker.wave.2")
                    Slider(value: $volume, in: 0...1) {
                        Text("Volume")
                    }
                    .frame(width: 100)
                }
            }
        }
    }
    
    private func togglePlayPause() {
        isPlaying.toggle()
        // TODO: Control MPVKit player
    }
    
    private func seek(to time: TimeInterval) {
        currentTime = time
        // TODO: Seek MPVKit player
    }
    
    private func seek(offset: TimeInterval) {
        currentTime = max(0, min(duration, currentTime + offset))
        seek(to: currentTime)
    }
    
    private func stepFrame(backward: Bool) {
        // TODO: Step frame by frame
    }
    
    private func performSmartPause() {
        Task {
            // Get lookback window from preferences (default 3 seconds)
            let lookbackWindow: TimeInterval = 3.0
            
            // Find best frame
            if let bestFrame = appState.focusScorer.findBestFrame(in: lookbackWindow) {
                // Perform OCR if enabled
                if appState.ocrEngine.isEnabled {
                    if let pixelBuffer = bestFrame.pixelBuffer {
                        appState.ocrEngine.recognizeText(in: pixelBuffer) { result in
                            // Handle OCR result
                            if let result = result {
                                print("OCR Result: \(result.text)")
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func setPlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        // TODO: Set MPVKit playback speed
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

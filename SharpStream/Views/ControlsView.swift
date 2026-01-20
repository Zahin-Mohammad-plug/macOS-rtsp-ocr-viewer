//
//  ControlsView.swift
//  SharpStream
//
//  Play/pause/scrub/speed controls
//

import SwiftUI
import Combine

struct ControlsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var playbackSpeed: Double = 1.0
    @State private var volume: Double = 1.0
    @State private var isDraggingSlider = false
    @State private var sliderValue: TimeInterval = 0
    @State private var timerCancellable: AnyCancellable?
    @State private var lastSeekTime: TimeInterval = -1
    @State private var seekInProgress = false
    @State private var isUpdatingSliderProgrammatically = false
    @State private var sliderChangeDebounceTimer: Timer?
    
    private var player: MPVPlayerWrapper? {
        appState.streamManager.player
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Timeline scrubber
            // Display current time on left, duration on right
            HStack {
                Text(formatTime(currentTime))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60, alignment: .leading)
                
                Slider(value: $sliderValue, in: 0...max(duration, 1)) {
                    Text("Timeline")
                }
                .onChange(of: sliderValue) { oldValue, newValue in
                    // Only handle user-initiated changes, not programmatic updates
                    if !isUpdatingSliderProgrammatically {
                        // User is dragging the slider
                        isDraggingSlider = true
                        
                        // Cancel any pending seek
                        sliderChangeDebounceTimer?.invalidate()
                        
                        // Debounce the seek - wait for user to stop dragging
                        sliderChangeDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                            // User stopped dragging - seek to the position
                            let targetTime = sliderValue
                            print("🎚️ Slider released at: \(String(format: "%.1f", targetTime))s")
                            seek(to: targetTime)
                            isDraggingSlider = false
                        }
                    }
                }
                
                Text(formatTime(duration))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
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
                    .onChange(of: playbackSpeed) { _, newValue in
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
                    .onChange(of: volume) { _, newValue in
                        setVolume(newValue)
                    }
                }
            }
        }
        .onAppear {
            // Initial sync with player state
            updatePlayerState()
            
            // Start timer to update player state - poll directly from player
            timerCancellable = Timer.publish(every: 0.1, on: .main, in: .common)
                .autoconnect()
                .sink { _ in
                    // Update from player periodically (every 0.1 seconds)
                    // Force player to update its currentTime property first
                    if let player = self.player, !self.isDraggingSlider, !self.seekInProgress {
                        // Force update by reading property (player should update via events, but we poll as backup)
                        let newTime = player.currentTime
                        let newDuration = player.duration
                        
                        // Update time display and slider if changed
                        if abs(newTime - self.currentTime) > 0.05 || newDuration != self.duration {
                            self.currentTime = newTime
                            // Only update slider if not being dragged by user
                            if !self.isDraggingSlider {
                                self.isUpdatingSliderProgrammatically = true
                                self.sliderValue = newTime
                                self.isUpdatingSliderProgrammatically = false
                            }
                            self.duration = newDuration
                        }
                        
                        self.isPlaying = player.isPlaying
                        self.playbackSpeed = player.playbackSpeed
                        self.volume = player.volume
                    }
                }
        }
        .onDisappear {
            // Stop timer when view disappears
            timerCancellable?.cancel()
            timerCancellable = nil
            sliderChangeDebounceTimer?.invalidate()
            sliderChangeDebounceTimer = nil
        }
    }
    
    private func togglePlayPause() {
        player?.togglePlayPause()
    }
    
    private func seek(to time: TimeInterval) {
        // Clamp time to valid range
        let clampedTime = max(0, min(time, max(duration, 1)))
        
        // Only seek if the change is significant (avoid micro-seeks)
        let currentPlayerTime = player?.currentTime ?? 0
        if abs(clampedTime - currentPlayerTime) < 0.1 {
            return // Too small a change, skip
        }
        
        // Set flag to prevent timer from overwriting during seek
        seekInProgress = true
        lastSeekTime = clampedTime
        
        // Cancel any pending slider debounce timer
        sliderChangeDebounceTimer?.invalidate()
        sliderChangeDebounceTimer = nil
        isDraggingSlider = false
        
        player?.seek(to: clampedTime)
        
        // Update local state immediately for UI responsiveness
        currentTime = clampedTime
        isUpdatingSliderProgrammatically = true
        sliderValue = clampedTime
        isUpdatingSliderProgrammatically = false
        
        // Clear seek flag after a delay to allow seek to complete
        // RTSP streams may have imprecise seeking, so we wait a bit longer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.seekInProgress = false
            // Force an update to sync with actual position
            if let player = self.player {
                let actualTime = player.currentTime
                // Only update if significantly different (account for imprecise seeking)
                if abs(actualTime - self.lastSeekTime) > 1.0 {
                    print("⚠️ Seek imprecise - requested \(String(format: "%.1f", self.lastSeekTime))s, got \(String(format: "%.1f", actualTime))s")
                    // Update to actual position (RTSP streams may not support frame-accurate seeking)
                    self.currentTime = actualTime
                    self.isUpdatingSliderProgrammatically = true
                    self.sliderValue = actualTime
                    self.isUpdatingSliderProgrammatically = false
                }
            }
            self.lastSeekTime = -1
        }
    }
    
    private func seek(offset: TimeInterval) {
        // Read actual current time from player, not local state (which may be stale)
        guard let player = player else { return }
        let actualCurrentTime = player.currentTime
        let newTime = max(0, min(duration, actualCurrentTime + offset))
        seek(to: newTime)
    }
    
    private func stepFrame(backward: Bool) {
        player?.stepFrame(backward: backward)
        // Time will be updated via onReceive when player updates
    }
    
    private func updatePlayerState() {
        // Initial sync with player state on appear
        guard let player = player else { return }
        currentTime = player.currentTime
        sliderValue = player.currentTime
        isPlaying = player.isPlaying
        duration = player.duration
        playbackSpeed = player.playbackSpeed
        volume = player.volume
    }
    
    private func performSmartPause() {
        Task {
            // Pause playback
            player?.pause()
            
            // Get lookback window from preferences (default 3 seconds)
            let lookbackWindow: TimeInterval = 3.0
            
            // Find best frame
            if let bestFrame = appState.focusScorer.findBestFrame(in: lookbackWindow) {
                // Seek to best frame
                if let player = player {
                    let currentTime = player.currentTime
                    let seekTime = bestFrame.timestamp.timeIntervalSince(Date()) + currentTime
                    player.seek(to: max(0, seekTime))
                }
                
                // Perform OCR if enabled
                if appState.ocrEngine.isEnabled {
                    if let pixelBuffer = bestFrame.pixelBuffer {
                        appState.ocrEngine.recognizeText(in: pixelBuffer) { result in
                            // Update app state with OCR result
                            DispatchQueue.main.async {
                                appState.currentOCRResult = result
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func setPlaybackSpeed(_ speed: Double) {
        player?.setSpeed(speed)
        // Speed will be updated via onReceive when player updates
    }
    
    private func setVolume(_ volume: Double) {
        player?.setVolume(volume)
        // Volume will be updated via onReceive when player updates
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

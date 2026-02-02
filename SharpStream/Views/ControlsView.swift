//
//  ControlsView.swift
//  SharpStream
//
//  Play/pause/scrub/speed controls
//

import SwiftUI
import Combine
import QuartzCore

struct ControlsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("lookbackWindow") private var lookbackWindow: Double = 3.0
    @AppStorage("autoOCROnSmartPause") private var autoOCROnSmartPause: Bool = true
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
    @State private var lastUserSliderValue: TimeInterval = -1
    @State private var lastSeekCompletionTime: TimeInterval = 0 // Track when seek actually completed
    @State private var controlStatusMessage: String?
    @State private var messageClearWorkItem: DispatchWorkItem?
    
    private var player: MPVPlayerWrapper? {
        appState.streamManager.player
    }

    private var seekMode: SeekMode {
        appState.streamManager.seekMode
    }

    private var canScrubTimeline: Bool {
        seekMode.allowsTimelineScrubbing && duration > 0
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Timeline scrubber
            // Display current time on left, duration on right
            HStack {
                Text(formatTime(currentTime))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60, alignment: .leading)
                    .accessibilityIdentifier("currentTimeLabel")
                
                Slider(value: $sliderValue, in: 0...max(duration, 1)) {
                    Text("Timeline")
                }
                .accessibilityIdentifier("timelineSlider")
                .disabled(!canScrubTimeline || seekInProgress)
                .onChange(of: sliderValue) { oldValue, newValue in
                    guard canScrubTimeline else { return }
                    // Only handle user-initiated changes, not programmatic updates
                    // Also don't handle if a seek is already in progress
                    if !isUpdatingSliderProgrammatically && !seekInProgress {
                        // Check if this is a significant change (user dragging, not just timer drift)
                        let change = abs(newValue - oldValue)

                        // Require larger change to avoid reacting to playback position drift
                        // Especially important for RTSP streams with imprecise seeking
                        if change > 0.5 {
                            // User is dragging the slider
                            isDraggingSlider = true
                            lastUserSliderValue = newValue

                            // Cancel any pending seek timer
                            if let existingTimer = sliderChangeDebounceTimer {
                                existingTimer.invalidate()
                                sliderChangeDebounceTimer = nil
                            }

                            // Debounce the seek - wait for user to stop dragging
                            let targetTime = newValue
                            sliderChangeDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [targetTime] timer in
                                // Double-check timer is still valid and we haven't started seeking
                                guard timer.isValid, !self.seekInProgress, self.isDraggingSlider else {
                                    self.isDraggingSlider = false
                                    return
                                }

                                let currentSliderValue = self.sliderValue
                                let timeSinceLastSeek = CACurrentMediaTime() - self.lastSeekCompletionTime

                                // Only seek if:
                                // 1. Slider value is still close to target (user stopped dragging)
                                // 2. Not in middle of programmatic update
                                // 3. Change is significant enough to warrant a seek
                                // 4. Enough time has passed since the last seek (prevent rapid loops)
                                if abs(currentSliderValue - targetTime) < 0.5 &&
                                   !self.isUpdatingSliderProgrammatically &&
                                   abs(currentSliderValue - (self.player?.currentTime ?? 0)) > 0.5 &&
                                   timeSinceLastSeek > 1.5 {
                                    print("🎚️ Slider released at: \(String(format: "%.1f", currentSliderValue))s")
                                    self.seek(to: currentSliderValue)
                                    self.isDraggingSlider = false
                                    self.lastUserSliderValue = -1
                                } else {
                                    // Conditions not met - don't seek, just clear dragging state
                                    self.isDraggingSlider = false
                                }
                            }
                        }
                    }
                }
                
                Text(formatTime(duration))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
                    .accessibilityIdentifier("durationTimeLabel")
            }

            HStack(spacing: 8) {
                Text(seekModeLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("seekModeLabel")
                Spacer()
                if let controlStatusMessage {
                    Text(controlStatusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("controlStatusMessage")
                }
            }
            
            HStack {
                // Play/Pause
                Button(action: togglePlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 30, height: 30)
                }
                .accessibilityIdentifier("playPauseButton")
                .keyboardShortcut(.space, modifiers: [])
                
                // Rewind 10s
                Button(action: { seek(offset: -10) }) {
                    Image(systemName: "gobackward.10")
                }
                .accessibilityIdentifier("rewind10Button")
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(!seekMode.allowsRelativeSeek || seekInProgress)
                
                // Forward 10s
                Button(action: { seek(offset: 10) }) {
                    Image(systemName: "goforward.10")
                }
                .accessibilityIdentifier("forward10Button")
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(!seekMode.allowsRelativeSeek || seekInProgress)
                
                Spacer()
                
                // Frame backward
                Button(action: { stepFrame(backward: true) }) {
                    Image(systemName: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(seekMode != .absolute)
                
                // Frame forward
                Button(action: { stepFrame(backward: false) }) {
                    Image(systemName: "chevron.right")
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(seekMode != .absolute)
                
                Spacer()
                
                // Smart Pause
                Button("Smart Pause") {
                    performSmartPause()
                }
                .accessibilityIdentifier("smartPauseButton")
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
                    .accessibilityIdentifier("volumeSlider")
                    .frame(width: 100)
                    .onChange(of: volume) { _, newValue in
                        setVolume(newValue)
                    }
                }

                ExportView()
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

                            // Only update slider if not being dragged by user and not seeking
                            // Also check if we're in a cooldown period after a seek - if so, use larger threshold
                            let timeSinceLastSeek = CACurrentMediaTime() - self.lastSeekCompletionTime
                            let inCooldown = timeSinceLastSeek < 1.5
                            let sliderThreshold = inCooldown ? 0.3 : 0.1 // Larger threshold during cooldown

                            if self.canScrubTimeline && !self.isDraggingSlider && !self.seekInProgress {
                                // Only update if the change is significant to avoid micro-updates triggering onChange
                                if abs(newTime - self.sliderValue) > sliderThreshold {
                                    self.isUpdatingSliderProgrammatically = true
                                    self.sliderValue = newTime
                                    self.isUpdatingSliderProgrammatically = false
                                }
                            } else if !self.canScrubTimeline && self.sliderValue != 0 {
                                self.isUpdatingSliderProgrammatically = true
                                self.sliderValue = 0
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
            messageClearWorkItem?.cancel()
            messageClearWorkItem = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TogglePlayPause"))) { _ in
            togglePlayPause()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SeekBackward"))) { _ in
            seek(offset: -10)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SeekForward"))) { _ in
            seek(offset: 10)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("StepFrameBackward"))) { _ in
            stepFrame(backward: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("StepFrameForward"))) { _ in
            stepFrame(backward: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SmartPause"))) { _ in
            performSmartPause()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SetPlaybackSpeed"))) { notification in
            if let speed = notification.object as? Double {
                setPlaybackSpeed(speed)
            }
        }
    }
    
    private func togglePlayPause() {
        player?.togglePlayPause()
    }
    
    private func seek(to time: TimeInterval) {
        guard canScrubTimeline else {
            showControlMessage("Timeline seeking is unavailable for this stream.")
            return
        }

        // Don't seek if already seeking
        if seekInProgress {
            return
        }

        guard let player = player else {
            showControlMessage("No active player available for seek.")
            return
        }
        
        // Clamp time to valid range
        let clampedTime = max(0, min(time, max(duration, 1)))
        
        // Only seek if the change is significant (avoid micro-seeks)
        let currentPlayerTime = player.currentTime
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
        lastUserSliderValue = -1
        
        let didSeek = player.seek(to: clampedTime)
        if !didSeek {
            seekInProgress = false
            lastSeekTime = -1
            showControlMessage("Seek command was rejected by the player.")
            return
        }
        
        // Update local state immediately for UI responsiveness
        currentTime = clampedTime
        isUpdatingSliderProgrammatically = true
        sliderValue = clampedTime
        isUpdatingSliderProgrammatically = false
        
        // Clear seek flag after a delay to allow seek to complete
        // RTSP streams may have imprecise seeking, so we wait a bit longer
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            // Only update if lastSeekTime is still valid (not reset)
            if self.lastSeekTime >= 0 {
                if let player = self.player {
                    let actualTime = player.currentTime
                    // Only log if significantly different (account for imprecise seeking)
                    // But DON'T update slider - let the timer handle it naturally to avoid loops
                    if abs(actualTime - self.lastSeekTime) > 1.0 {
                        print("⚠️ Seek imprecise - requested \(String(format: "%.1f", self.lastSeekTime))s, got \(String(format: "%.1f", actualTime))s")
                        // Just update currentTime, not sliderValue - let timer update slider naturally
                        self.currentTime = actualTime
                    }
                }
                self.lastSeekTime = -1
            }
            // Clear seek flag to allow new seeks and record completion time
            self.seekInProgress = false
            self.lastSeekCompletionTime = CACurrentMediaTime()
        }
    }
    
    private func seek(offset: TimeInterval) {
        guard let player = player else { return }

        switch seekMode {
        case .absolute:
            // Read actual current time from player, not local state (which may be stale)
            let actualCurrentTime = player.currentTime
            let newTime = max(0, min(duration, actualCurrentTime + offset))
            seek(to: newTime)

        case .liveBuffered:
            if seekInProgress {
                return
            }
            seekInProgress = true
            let didSeek = player.seek(offset: offset)
            seekInProgress = false
            if didSeek {
                lastSeekCompletionTime = CACurrentMediaTime()
                let direction = offset < 0 ? "back" : "forward"
                showControlMessage("Live seek requested (\(direction) \(Int(abs(offset)))s).")
            } else {
                showControlMessage("Live seek failed for this stream.")
            }

        case .disabled:
            showControlMessage("Seeking is disabled for this stream.")
        }
    }
    
    private func stepFrame(backward: Bool) {
        player?.stepFrame(backward: backward)
        // Time will be updated via onReceive when player updates
    }
    
    private func updatePlayerState() {
        // Initial sync with player state on appear
        guard let player = player else { return }
        currentTime = player.currentTime
        sliderValue = canScrubTimeline ? player.currentTime : 0
        isPlaying = player.isPlaying
        duration = player.duration
        playbackSpeed = player.playbackSpeed
        volume = player.volume
    }
    
    private func performSmartPause() {
        Task { @MainActor in
            // Pause playback
            player?.pause()
            
            // Get lookback window from preferences
            let lookbackWindow = TimeInterval(lookbackWindow)
            
            // Find best frame
            guard let bestFrame = appState.focusScorer.findBestFrame(in: lookbackWindow) else {
                showControlMessage("Smart Pause found no recent frames in the lookback window.")
                return
            }

            let frameAge = Date().timeIntervalSince(bestFrame.timestamp)
            let maxStaleness = max(lookbackWindow + 1.0, 8.0)
            guard frameAge >= 0, frameAge <= maxStaleness else {
                showControlMessage("Best frame is stale; try again while playback is active.")
                return
            }

            // Best-effort seek behavior based on explicit capability.
            if let player = player {
                switch seekMode {
                case .absolute:
                    let targetTime = max(0, player.currentTime - frameAge)
                    if !player.seek(to: targetTime) {
                        showControlMessage("Smart Pause could not seek to the selected frame.")
                    }
                case .liveBuffered:
                    if !player.seek(offset: -frameAge) {
                        showControlMessage("Smart Pause could not perform live buffered seek.")
                    }
                case .disabled:
                    showControlMessage("Smart Pause selected a frame, but seek is disabled.")
                }
            }

            // Perform OCR only when preference and runtime state both allow it.
            if autoOCROnSmartPause && appState.ocrEngine.isEnabled {
                if let pixelBuffer = bestFrame.pixelBuffer {
                    appState.ocrEngine.recognizeText(in: pixelBuffer) { result in
                        DispatchQueue.main.async {
                            appState.currentOCRResult = result
                        }
                    }
                } else {
                    showControlMessage("Smart Pause found a frame but pixel data is unavailable.")
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

    private var seekModeLabel: String {
        switch seekMode {
        case .absolute:
            return "Seek Mode: Timeline"
        case .liveBuffered:
            return "Seek Mode: Live Buffer"
        case .disabled:
            return "Seek Mode: Disabled"
        }
    }

    private func showControlMessage(_ message: String) {
        controlStatusMessage = message
        messageClearWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            self.controlStatusMessage = nil
        }
        messageClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }
}

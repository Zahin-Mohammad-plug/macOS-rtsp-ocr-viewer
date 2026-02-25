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
    @AppStorage("maxBufferLength") private var maxBufferLength: Int = 30
    @AppStorage("copyCommandMode") private var copyCommandModeRaw: String = CopyCommandMode.ocrText.rawValue
    @AppStorage("use24HourClock") private var use24HourClock: Bool = false
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
    @State private var smartPauseSelection: SmartPauseSelection?
    @State private var selectionClearWorkItem: DispatchWorkItem?
    @State private var lastIsPlaying: Bool = false
    @State private var isHoveringSlider = false
    @State private var liveScrubAnchor: LiveScrubAnchor?

    private struct LiveScrubAnchor: Equatable {
        let startDate: Date
        let liveEdgeDate: Date
        let windowSeconds: TimeInterval
    }
    
    private var player: MPVPlayerWrapper? {
        appState.streamManager.player
    }

    private var seekMode: SeekMode {
        appState.streamManager.seekMode
    }

    private var liveDVRState: LiveDVRState {
        appState.streamManager.liveDVRState
    }

    private var canScrubTimeline: Bool {
        switch seekMode {
        case .absolute:
            return duration > 0
        case .liveBuffered:
            return liveDVRState.windowSeconds > 1.0
        case .disabled:
            return false
        }
    }

    private var maxBufferWindowSeconds: TimeInterval {
        TimeInterval(maxBufferLength * 60)
    }

    private var liveSliderMaximum: TimeInterval {
        max(liveDVRState.windowSeconds, 1)
    }

    private var liveScrubWindowSeconds: TimeInterval {
        if isLiveMode, let anchor = liveScrubAnchor, isDraggingSlider {
            return max(anchor.windowSeconds, 1)
        }
        return liveSliderMaximum
    }

    private var timelineSliderMaximum: TimeInterval {
        isLiveMode ? liveScrubWindowSeconds : max(duration, 1)
    }

    private var isLiveMode: Bool {
        seekMode == .liveBuffered
    }

    private var liveScrubStartDate: Date {
        if isLiveMode, let anchor = liveScrubAnchor, isDraggingSlider {
            return anchor.startDate
        }
        return liveDVRState.dvrStartDate
    }

    private var liveScrubLiveEdgeDate: Date {
        if isLiveMode, let anchor = liveScrubAnchor, isDraggingSlider {
            return anchor.liveEdgeDate
        }
        return liveDVRState.liveEdgeDate
    }

    private var liveScrubCurrentDate: Date {
        let clampedValue = max(0, min(sliderValue, liveScrubWindowSeconds))
        return liveScrubStartDate.addingTimeInterval(clampedValue)
    }

    private var currentPlaybackDisplayTime: TimeInterval {
        isDraggingSlider ? sliderValue : currentTime
    }

    private var shouldShowScrubPreview: Bool {
        canScrubTimeline && (isDraggingSlider || isHoveringSlider)
    }

    private var scrubPreviewText: String {
        if isLiveMode {
            return formatClockTime(liveScrubCurrentDate)
        }
        return formatTime(sliderValue)
    }

    private var smartPauseMarkerNormalized: Double? {
        guard let selection = smartPauseSelection,
              selection.seekMode == .absolute,
              duration > 0,
              let playbackTime = selection.playbackTime else {
            return nil
        }
        return max(0, min(1, playbackTime / duration))
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Timeline scrubber
            // Display current time on left, duration on right
            HStack {
                if isLiveMode {
                    HStack(spacing: 6) {
                        Text(formatClockTime(liveScrubStartDate))
                        Text("•")
                            .foregroundColor(.secondary)
                        Text(formatClockTime(liveScrubCurrentDate))
                    }
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 170, alignment: .leading)
                    .accessibilityIdentifier("liveDvrStartLabel")
                } else {
                    Text(formatTime(currentPlaybackDisplayTime))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 80, alignment: .leading)
                        .accessibilityIdentifier("currentTimeLabel")
                }

                ZStack(alignment: .leading) {
                    Slider(value: $sliderValue, in: 0...timelineSliderMaximum) {
                        Text("Timeline")
                    }
                    .accessibilityIdentifier("timelineSlider")
                    .disabled(!canScrubTimeline || seekInProgress)
                    .onHover { hovering in
                        isHoveringSlider = hovering
                    }
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
                                if isLiveMode && !isDraggingSlider {
                                    liveScrubAnchor = LiveScrubAnchor(
                                        startDate: liveDVRState.dvrStartDate,
                                        liveEdgeDate: liveDVRState.liveEdgeDate,
                                        windowSeconds: liveDVRState.windowSeconds
                                    )
                                }
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
                                        self.liveScrubAnchor = nil
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
                                       abs(currentSliderValue - (self.isLiveMode ? self.liveSliderMaximum - self.liveDVRState.lagSeconds : (self.player?.currentTime ?? 0))) > 0.5 &&
                                       timeSinceLastSeek > 1.5 {
                                        print("🎚️ Slider released at: \(String(format: "%.1f", currentSliderValue))s")
                                        self.handleSliderSeek(to: currentSliderValue)
                                        self.isDraggingSlider = false
                                        self.lastUserSliderValue = -1
                                        self.liveScrubAnchor = nil
                                    } else {
                                        // Conditions not met - don't seek, just clear dragging state
                                        self.isDraggingSlider = false
                                        self.liveScrubAnchor = nil
                                    }
                                }
                            }
                        }
                    }

                    if shouldShowScrubPreview {
                        GeometryReader { geometry in
                            let progress = timelineSliderMaximum > 0 ? sliderValue / timelineSliderMaximum : 0
                            let clamped = max(0, min(1, progress))
                            let x = geometry.size.width * clamped
                            Text(scrubPreviewText)
                                .font(.system(.caption2, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.thinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .position(x: x, y: 0)
                                .offset(y: -18)
                        }
                        .allowsHitTesting(false)
                    }

                    if let marker = smartPauseMarkerNormalized {
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(Color.orange)
                                .frame(width: 2, height: 18)
                                .position(
                                    x: max(1, min(geometry.size.width - 1, geometry.size.width * marker)),
                                    y: geometry.size.height / 2
                                )
                        }
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("smartPauseSelectionMarker")
                    }
                }

                Text(isLiveMode ? formatClockTime(liveScrubLiveEdgeDate) : formatTime(duration))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 80, alignment: .trailing)
                    .accessibilityIdentifier(isLiveMode ? "liveEdgeLabel" : "durationTimeLabel")
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

            if shouldExposeSmartPauseDiagnostics {
                HStack {
                    Spacer()
                    Text(appState.lastSmartPauseDiagnostics?.jsonString ?? "smart-pause-diagnostics: none")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(4)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("smartPauseDiagnosticsLabel")
                }
            }

            if let selection = smartPauseSelection, selection.seekMode == .liveBuffered {
                HStack {
                    Spacer()
                    Text("Smart Pause selected from live buffer")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("smartPauseLiveBadge")
                }
            }

            if smartPauseMarkerNormalized != nil {
                HStack {
                    Spacer()
                    Text("Smart Pause marker active")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("smartPauseMarkerStatus")
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

                Button("Jump to Live") {
                    jumpToLive()
                }
                .accessibilityIdentifier("jumpToLiveButton")
                .disabled(!isLiveMode || liveDVRState.isAtLiveEdge || seekInProgress)
                
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

                HStack(spacing: 6) {
                    Button("Copy Text") {
                        NotificationCenter.default.post(name: .copyOCRTextNow, object: nil)
                    }
                    .accessibilityIdentifier("quickCopyTextButton")

                    Button("Copy Frame") {
                        NotificationCenter.default.post(name: .copyFrameNow, object: nil)
                    }
                    .accessibilityIdentifier("quickCopyFrameButton")

                    Button("Quick Save") {
                        NotificationCenter.default.post(name: .quickSaveFrame, object: nil)
                    }
                    .accessibilityIdentifier("quickSaveFrameButton")

                    Picker("", selection: $copyCommandModeRaw) {
                        ForEach(CopyCommandMode.allCases, id: \.rawValue) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                    .accessibilityIdentifier("copyCommandModePicker")
                }

                ExportView()
            }
        }
        .accessibilityIdentifier("controlsContainer")
        .accessibilityElement(children: .contain)
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
                        appState.streamManager.updateLiveDVRState(
                            currentPlaybackTime: newTime,
                            isPlaying: player.isPlaying,
                            player: player,
                            maxWindowSeconds: maxBufferWindowSeconds
                        )

                        // Update time display if changed
                        if abs(newTime - self.currentTime) > 0.05 || newDuration != self.duration {
                            self.currentTime = newTime
                            self.duration = newDuration
                        }

                        // Only update slider if not being dragged by user and not seeking
                        // Also check if we're in a cooldown period after a seek - if so, use larger threshold
                        let timeSinceLastSeek = CACurrentMediaTime() - self.lastSeekCompletionTime
                        let inCooldown = timeSinceLastSeek < 1.5
                        let sliderThreshold = inCooldown ? 0.3 : 0.1 // Larger threshold during cooldown

                        if self.canScrubTimeline && !self.isDraggingSlider && !self.seekInProgress {
                            if self.isLiveMode {
                                let lag = self.liveDVRState.lagSeconds
                                let targetValue = max(0, min(self.liveSliderMaximum, self.liveSliderMaximum - lag))
                                if abs(targetValue - self.sliderValue) > sliderThreshold {
                                    self.isUpdatingSliderProgrammatically = true
                                    self.sliderValue = targetValue
                                    self.isUpdatingSliderProgrammatically = false
                                }
                            } else {
                                // Only update if the change is significant to avoid micro-updates triggering onChange
                                if abs(newTime - self.sliderValue) > sliderThreshold {
                                    self.isUpdatingSliderProgrammatically = true
                                    self.sliderValue = newTime
                                    self.isUpdatingSliderProgrammatically = false
                                }
                            }
                        } else if !self.canScrubTimeline && self.sliderValue != 0 {
                            self.isUpdatingSliderProgrammatically = true
                            self.sliderValue = 0
                            self.isUpdatingSliderProgrammatically = false
                        }

                        let playingNow = player.isPlaying
                        if playingNow && !self.lastIsPlaying {
                            appState.currentOCRResult = nil
                        }
                        self.lastIsPlaying = playingNow
                        self.isPlaying = playingNow
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
            selectionClearWorkItem?.cancel()
            selectionClearWorkItem = nil
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

    private func handleSliderSeek(to value: TimeInterval) {
        if isLiveMode {
            let targetLag = max(0, liveScrubWindowSeconds - value)
            seekToLiveLag(targetLag)
        } else {
            seek(to: value)
        }
    }

    private func seekToLiveLag(_ targetLag: TimeInterval) {
        let clampedLag = max(0, min(targetLag, liveSliderMaximum))
        let currentLag = liveDVRState.lagSeconds
        let offset = currentLag - clampedLag
        guard abs(offset) > 0.1 else { return }
        seek(offset: offset)
    }

    private func jumpToLive() {
        guard !seekInProgress else { return }
        if isLiveMode, appState.streamManager.seekToLiveEdge() {
            seekInProgress = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.seekInProgress = false
                self.lastSeekCompletionTime = CACurrentMediaTime()
            }
            return
        }
        seekToLiveLag(0)
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
        liveScrubAnchor = nil
        
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
            let clampedOffset = StreamManager.clampLiveSeekOffset(offset, lagSeconds: liveDVRState.lagSeconds)
            if offset > 0 && clampedOffset <= 0.1 {
                seekInProgress = false
                showControlMessage("Already at live edge.")
                return
            }
            let didSeek = player.seek(offset: clampedOffset)
            seekInProgress = false
            if didSeek {
                lastSeekCompletionTime = CACurrentMediaTime()
                let direction = offset < 0 ? "back" : "forward"
                showControlMessage("Live seek requested (\(direction) \(Int(abs(clampedOffset)))s).")
            } else {
                if offset > 0 && appState.streamManager.seekToLiveEdge() {
                    lastSeekCompletionTime = CACurrentMediaTime()
                    showControlMessage("Jumped to live edge.")
                } else {
                    showControlMessage("Live seek failed for this stream.")
                }
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
        appState.streamManager.updateLiveDVRState(
            currentPlaybackTime: player.currentTime,
            isPlaying: player.isPlaying,
            player: player,
            maxWindowSeconds: maxBufferWindowSeconds
        )
        currentTime = player.currentTime
        if canScrubTimeline {
            if isLiveMode {
                sliderValue = max(0, min(liveSliderMaximum, liveSliderMaximum - liveDVRState.lagSeconds))
            } else {
                sliderValue = player.currentTime
            }
        } else {
            sliderValue = 0
        }
        isPlaying = player.isPlaying
        lastIsPlaying = player.isPlaying
        duration = player.duration
        playbackSpeed = player.playbackSpeed
        volume = player.volume
    }
    
    private func performSmartPause() {
        Task { @MainActor in
            guard let player = player else {
                clearSmartPauseFeedback()
                showControlMessage("Smart Pause is unavailable because no player is active.")
                appState.lastSmartPauseDiagnostics = nil
                return
            }

            let result = await appState.smartPauseCoordinator.perform(
                request: SmartPauseRequest(
                    lookbackSeconds: TimeInterval(lookbackWindow),
                    seekMode: seekMode,
                    currentPlaybackTime: player.currentTime,
                    autoOCREnabled: autoOCROnSmartPause
                ),
                player: player
            )

            appState.lastSmartPauseDiagnostics = result.diagnostics

            if let selection = result.selection {
                setSmartPauseFeedback(selection)
            } else {
                clearSmartPauseFeedback()
            }

            showControlMessage(result.statusMessage)

            guard result.isSuccess, let ocrPixelBuffer = result.ocrPixelBuffer else {
                return
            }

            appState.ocrEngine.recognizeText(in: ocrPixelBuffer) { result in
                DispatchQueue.main.async {
                    appState.currentOCRResult = result
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

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let clockFormatter12h: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        return formatter
    }()

    private func formatClockTime(_ date: Date) -> String {
        if use24HourClock {
            return Self.clockFormatter.string(from: date)
        }
        return Self.clockFormatter12h.string(from: date)
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

    private var shouldExposeSmartPauseDiagnostics: Bool {
        ProcessInfo.processInfo.environment["SHARPSTREAM_ENABLE_SMART_PAUSE_DIAGNOSTICS"] == "1"
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

    private func setSmartPauseFeedback(_ selection: SmartPauseSelection) {
        smartPauseSelection = selection
        selectionClearWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            self.smartPauseSelection = nil
        }
        selectionClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }

    private func clearSmartPauseFeedback() {
        selectionClearWorkItem?.cancel()
        selectionClearWorkItem = nil
        smartPauseSelection = nil
    }
}

//
//  ControlsView.swift
//  SharpStream
//
//  Timeline + playback controls. The control row adapts to the available width
//  (labels → icons → overflow menu) instead of overflowing the window.
//

import SwiftUI

struct ControlsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var streamManager: StreamManager

    var body: some View {
        VStack(spacing: 6) {
            if let player = streamManager.player {
                TimelineRow(player: player, clock: player.clock, liveStore: streamManager.liveStore)
            } else {
                TimelineRow.placeholder
            }

            ViewThatFits(in: .horizontal) {
                ControlRow(layout: .full)
                ControlRow(layout: .compact)
                ControlRow(layout: .minimal)
            }
        }
    }
}

// MARK: - Timeline

struct TimelineRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var streamManager: StreamManager
    @AppStorage(UserDefaultsKey.use24HourClock) private var use24HourClock = false
    @ObservedObject var player: MPVPlayerWrapper
    @ObservedObject var clock: PlaybackClock
    @ObservedObject var liveStore: LiveDVRStore

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var lastPreviewSeek = Date.distantPast
    @State private var releaseGuardUntil = Date.distantPast

    static var placeholder: some View {
        HStack(spacing: 10) {
            Text("--:--").monospacedDigit().foregroundStyle(.tertiary)
            Slider(value: .constant(0), in: 0...1).disabled(true)
            Text("--:--").monospacedDigit().foregroundStyle(.tertiary)
        }
        .font(.callout)
        .accessibilityIdentifier("timelineSlider")
    }

    private var mode: SeekMode { streamManager.seekMode }
    private var live: LiveDVRState { liveStore.state }

    private var range: ClosedRange<Double> {
        switch mode {
        case .absolute: return 0...max(player.duration, 0.1)
        case .liveBuffered: return 0...max(live.windowSeconds, 0.1)
        case .disabled: return 0...1
        }
    }

    private var actualPosition: Double {
        switch mode {
        case .absolute: return clock.time
        case .liveBuffered: return max(0, live.windowSeconds - live.lagSeconds)
        case .disabled: return 0
        }
    }

    private var canScrub: Bool {
        switch mode {
        case .absolute: return player.duration > 0
        case .liveBuffered: return live.windowSeconds > 1
        case .disabled: return false
        }
    }

    private var displayedPosition: Double {
        (isScrubbing || Date() < releaseGuardUntil) ? scrubValue : actualPosition
    }

    var body: some View {
        HStack(spacing: 10) {
            leadingLabel
                .frame(minWidth: 56, alignment: .leading)

            ZStack(alignment: .leading) {
                Slider(
                    value: Binding(
                        get: { min(max(displayedPosition, range.lowerBound), range.upperBound) },
                        set: { newValue in
                            scrubValue = newValue
                            previewSeekIfNeeded(newValue)
                        }
                    ),
                    in: range,
                    onEditingChanged: handleEditingChanged
                )
                .disabled(!canScrub)
                .accessibilityIdentifier("timelineSlider")

                if let marker = smartPauseMarker {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Color.orange)
                            .frame(width: 3, height: 14)
                            .position(x: 8 + (geometry.size.width - 16) * marker, y: geometry.size.height / 2)
                    }
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("smartPauseSelectionMarker")
                }
            }

            trailingLabel
                .frame(minWidth: 56, alignment: .trailing)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var leadingLabel: some View {
        switch mode {
        case .liveBuffered:
            Text(clock(live.dvrStartDate.addingTimeInterval(displayedPosition)))
                .monospacedDigit()
                .accessibilityIdentifier("liveDvrStartLabel")
        default:
            Text(Self.format(displayedPosition))
                .monospacedDigit()
                .accessibilityIdentifier("currentTimeLabel")
        }
    }

    @ViewBuilder
    private var trailingLabel: some View {
        switch mode {
        case .liveBuffered:
            let lag = isScrubbing ? max(0, live.windowSeconds - scrubValue) : live.lagSeconds
            if lag <= 1.5 {
                Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("liveEdgeLabel")
            } else {
                Text("−" + Self.format(lag))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("liveEdgeLabel")
            }
        case .absolute:
            Text(Self.format(player.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("durationTimeLabel")
        case .disabled:
            Text("--:--")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    private var smartPauseMarker: Double? {
        guard mode == .absolute, player.duration > 0,
              let time = appState.smartPauseSelection?.playbackTime else { return nil }
        return max(0, min(1, time / player.duration))
    }

    private func handleEditingChanged(_ editing: Bool) {
        if editing {
            scrubValue = actualPosition
            isScrubbing = true
        } else {
            appState.seek(toTimelinePosition: scrubValue, exact: mode == .absolute)
            // Hold the released value briefly so the thumb doesn't jump back
            // before the player reports its new position.
            releaseGuardUntil = Date().addingTimeInterval(0.6)
            isScrubbing = false
        }
    }

    /// Files: show frames while dragging with cheap keyframe seeks.
    private func previewSeekIfNeeded(_ value: Double) {
        guard isScrubbing, mode == .absolute else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPreviewSeek) > 0.15 else { return }
        lastPreviewSeek = now
        appState.seek(toTimelinePosition: value, exact: false)
    }

    private func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = use24HourClock ? "HH:mm:ss" : "h:mm:ss a"
        return formatter.string(from: date)
    }

    static func format(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "--:--" }
        let total = Int(time)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Control row

private struct ControlRow: View {
    enum Layout { case full, compact, minimal }

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var streamManager: StreamManager
    let layout: Layout

    private var player: MPVPlayerWrapper? { streamManager.player }
    private var mode: SeekMode { streamManager.seekMode }
    private var hasPlayer: Bool { player != nil }
    private var labelStyle: some LabelStyle { layout == .full ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly) }

    var body: some View {
        HStack(spacing: 6) {
            transport
            Spacer(minLength: 12)
            actions
            Spacer(minLength: 12)
            trailing
        }
        .labelStyle(labelStyle)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var transport: some View {
        HStack(spacing: 2) {
            if let player {
                PlayPauseButton(player: player)
            } else {
                Button {} label: { Image(systemName: "play.fill").frame(width: 22, height: 22) }
                    .disabled(true)
            }

            iconButton("gobackward.10", help: "Back 10 seconds (⌥⌘←)", id: "rewind10Button") { appState.seek(by: -10) }
                .disabled(!mode.allowsRelativeSeek)
            iconButton("goforward.10", help: "Forward 10 seconds (⌥⌘→)", id: "forward10Button") { appState.seek(by: 10) }
                .disabled(!mode.allowsRelativeSeek)

            if layout != .minimal, mode == .absolute {
                iconButton("backward.frame", help: "Previous frame ( , )", id: "previousFrameButton") { appState.stepFrame(backward: true) }
                iconButton("forward.frame", help: "Next frame ( . )", id: "nextFrameButton") { appState.stepFrame(backward: false) }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                appState.smartPause()
            } label: {
                Label("Smart Pause", systemImage: "scope")
            }
            .help("Pause on the sharpest frame from the last few seconds (⌘S)")
            .accessibilityIdentifier("smartPauseButton")
            .disabled(!hasPlayer || appState.isPerformingSmartPause)

            Button {
                appState.recognizeText()
            } label: {
                Label("Recognize Text", systemImage: "text.viewfinder")
            }
            .help("Pause and recognize text in the current frame (⌘R)")
            .accessibilityIdentifier("recognizeTextButton")
            .disabled(!hasPlayer || appState.isRecognizingText)

            if mode == .liveBuffered, let player {
                JumpToLiveButton(player: player, liveStore: streamManager.liveStore)
            }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 6) {
            if layout != .minimal, let player {
                SpeedMenu(player: player)
                VolumeControl(player: player, compact: layout != .full)
            }
            ExportMenu(includePlaybackItems: layout == .minimal)
        }
    }

    private func iconButton(_ systemImage: String, help: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
        }
        .help(help)
        .accessibilityIdentifier(id)
        .disabled(!hasPlayer)
    }
}

private struct JumpToLiveButton: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var player: MPVPlayerWrapper
    @ObservedObject var liveStore: LiveDVRStore

    var body: some View {
        Button {
            appState.jumpToLive()
        } label: {
            Label("Live", systemImage: "forward.end.alt")
        }
        .help("Jump to the live edge (⌘L)")
        .accessibilityIdentifier("jumpToLiveButton")
        .disabled(liveStore.state.isAtLiveEdge && player.isPlaying)
    }
}

private struct PlayPauseButton: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var player: MPVPlayerWrapper

    var body: some View {
        Button {
            appState.togglePlayPause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .frame(width: 22, height: 22)
        }
        .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
        .accessibilityIdentifier("playPauseButton")
    }
}

private struct SpeedMenu: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var player: MPVPlayerWrapper

    var body: some View {
        Menu {
            ForEach(PlaybackSpeed.options, id: \.self) { speed in
                Button {
                    appState.setSpeed(speed)
                } label: {
                    if abs(player.playbackSpeed - speed) < 0.001 {
                        Label(PlaybackSpeed.label(speed), systemImage: "checkmark")
                    } else {
                        Text(PlaybackSpeed.label(speed))
                    }
                }
            }
        } label: {
            Text(PlaybackSpeed.label(player.playbackSpeed))
                .monospacedDigit()
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback speed")
        .accessibilityIdentifier("speedMenu")
    }
}

private struct VolumeControl: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var player: MPVPlayerWrapper
    let compact: Bool
    @State private var showPopover = false

    private var icon: String {
        switch player.volume {
        case ..<0.01: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private var binding: Binding<Double> {
        Binding(get: { player.volume }, set: { appState.setVolume($0) })
    }

    var body: some View {
        if compact {
            Button {
                showPopover.toggle()
            } label: {
                Image(systemName: icon).frame(width: 20)
            }
            .buttonStyle(.borderless)
            .help("Volume")
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                Slider(value: binding, in: 0...1)
                    .frame(width: 140)
                    .padding(12)
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Slider(value: binding, in: 0...1)
                    .frame(width: 90)
                    .accessibilityIdentifier("volumeSlider")
            }
        }
    }
}

/// Type-erased label style so the row can switch styles by layout.
private struct AnyLabelStyle: LabelStyle {
    private let makeBodyClosure: (Configuration) -> AnyView

    init<S: LabelStyle>(_ style: S) {
        makeBodyClosure = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBodyClosure(configuration)
    }
}

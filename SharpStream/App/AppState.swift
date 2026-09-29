//
//  AppState.swift
//  SharpStream
//
//  Global app state and the single home for user actions. Menus, toolbar,
//  keyboard shortcuts and controls all call these methods directly — no
//  NotificationCenter broadcast bus, so an action works regardless of which
//  views happen to be on screen.
//

import SwiftUI
import AppKit
import Combine
import CoreVideo
import UniformTypeIdentifiers

/// A frame that was analyzed (Smart Pause and/or OCR) and is shown frozen on
/// top of the video while playback is paused, so OCR boxes always line up
/// with exactly the pixels that were recognized.
struct AnalyzedFrame: Identifiable {
    let id = UUID()
    let pixelBuffer: CVPixelBuffer
    let image: CGImage
    let playbackTime: TimeInterval?
    var ocrResult: OCRResult?

    var size: CGSize { CGSize(width: image.width, height: image.height) }
}

struct StatusMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}

enum UserDefaultsKey {
    static let lookbackWindow = "lookbackWindow"
    static let autoOCROnSmartPause = "autoOCROnSmartPause"
    static let maxBufferLength = "maxBufferLength"
    static let focusAlgorithm = "focusAlgorithm"
    static let ocrEnabled = "ocrEnabled"
    static let ocrLanguage = "ocrLanguage"
    static let ocrRecognitionLevel = "ocrRecognitionLevel"
    static let ocrLanguageCorrection = "ocrLanguageCorrection"
    static let ocrOverlayShowText = "ocrOverlayShowText"
    static let ocrOverlayShowBoxes = "ocrOverlayShowBoxes"
    static let showOCRInspector = "showOCRInspector"
    static let defaultExportFormat = "defaultExportFormat"
    static let defaultJPEGQuality = "defaultJPEGQuality"
    static let lastFrameExportDirectory = "lastFrameExportDirectory"
    static let use24HourClock = "use24HourClock"
    static let rtspTransport = "rtspTransport"
    static let hardwareDecoding = "hardwareDecoding"
    static let autoReconnect = "autoReconnect"
    static let rememberRecentStreams = "rememberRecentStreams"
    static let autoShowTextPanel = "autoShowTextPanel"
    static let playbackVolume = "playbackVolume"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            lookbackWindow: 3.0,
            autoOCROnSmartPause: true,
            maxBufferLength: 30,
            focusAlgorithm: FocusAlgorithm.laplacian.rawValue,
            ocrEnabled: true,
            ocrLanguage: "en-US",
            ocrRecognitionLevel: OCRRecognitionLevel.accurate.rawValue,
            ocrLanguageCorrection: false,
            ocrOverlayShowText: true,
            ocrOverlayShowBoxes: true,
            showOCRInspector: true,
            defaultExportFormat: "PNG",
            defaultJPEGQuality: 0.8,
            use24HourClock: false,
            rtspTransport: MPVPlayerWrapper.Options.RTSPTransport.tcp.rawValue,
            hardwareDecoding: true,
            autoReconnect: true,
            rememberRecentStreams: true,
            autoShowTextPanel: true,
            playbackVolume: 1.0
        ])
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var currentOCRResult: OCRResult?
    @Published private(set) var analyzedFrame: AnalyzedFrame?
    @Published private(set) var statusMessage: StatusMessage?
    @Published private(set) var smartPauseSelection: SmartPauseSelection?
    @Published private(set) var isRecognizingText = false
    @Published private(set) var isPerformingSmartPause = false
    @Published var lastSmartPauseDiagnostics: SmartPauseDiagnostics?
    /// Coarse, de-duplicated mirrors of stream state for menus. (Forwarding every
    /// StreamManager change would re-render the whole window several times a
    /// second on live streams; views that need fine-grained state observe
    /// StreamManager directly.)
    @Published private(set) var hasPlayer = false
    @Published private(set) var currentSeekMode: SeekMode = .disabled
    @Published private(set) var hasCurrentStream = false
    /// Bumped when saved/recent streams change so menus rebuild their lists.
    @Published private(set) var libraryRevision = 0
    @Published var showOCRInspector: Bool {
        didSet { UserDefaults.standard.set(showOCRInspector, forKey: UserDefaultsKey.showOCRInspector) }
    }

    /// Test runs (UI tests, and unit tests that use the app as their host) get
    /// throwaway storage and never show the resume prompt, so they neither
    /// depend on nor modify the user's real library/session. A modal resume
    /// prompt in the unit-test host used to block the main thread and hang
    /// the whole run.
    static let isUITesting: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["SHARPSTREAM_UI_TESTING"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()
    private static let testSandbox: URL? = isUITesting
        ? FileManager.default.temporaryDirectory.appendingPathComponent("SharpStreamUITest-\(UUID().uuidString)", isDirectory: true)
        : nil

    let streamManager = StreamManager()
    let focusScorer = FocusScorer()
    let ocrEngine = OCREngine()
    let exportManager = ExportManager()
    let streamDatabase = StreamDatabase(baseDirectory: AppState.testSandbox)
    let performanceMonitor = PerformanceMonitor()
    let recoveryStore = SessionRecoveryStore(fileURL: AppState.testSandbox?.appendingPathComponent("session_recovery.json"))
    let fileAccess = FileAccessStore()
    lazy var smartPauseCoordinator = SmartPauseCoordinator(focusScorer: focusScorer, ocrEngine: ocrEngine)

    private var cancellables = Set<AnyCancellable>()
    private var playerCancellables = Set<AnyCancellable>()
    private var statsUpdateTimer: Timer?
    private var statusClearWorkItem: DispatchWorkItem?
    private var keyMonitor: Any?
    private var playerWindows = NSHashTable<NSWindow>.weakObjects()
    private var didCheckRecovery = false
    private var ocrRunsInFlight = 0

    var player: MPVPlayerWrapper? { streamManager.player }

    init() {
        UserDefaultsKey.registerDefaults()
        let defaults = UserDefaults.standard
        showOCRInspector = defaults.bool(forKey: UserDefaultsKey.showOCRInspector)

        fileAccess.isPersistenceEnabled = !Self.isUITesting
        streamManager.database = streamDatabase
        streamManager.focusScorer = focusScorer
        streamManager.recoveryStore = recoveryStore

        applyPreferences()

        streamManager.$player
            .removeDuplicates { $0 === $1 }
            .sink { [weak self] player in
                self?.hasPlayer = player != nil
                self?.bind(to: player)
            }
            .store(in: &cancellables)

        streamManager.$seekMode
            .removeDuplicates()
            .sink { [weak self] mode in self?.currentSeekMode = mode }
            .store(in: &cancellables)

        streamManager.$currentStream
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] value in self?.hasCurrentStream = value }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .savedStreamsUpdated)
            .merge(with: NotificationCenter.default.publisher(for: .recentStreamsUpdated))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.libraryRevision += 1 }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyPreferences() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                // A clean quit is not an "interrupted" session.
                self?.recoveryStore.clear()
                self?.streamManager.player?.cleanup()
            }
            .store(in: &cancellables)

        if !Self.isUITesting { Self.removeLegacyBufferFiles() }
        // Warm up Vision after launch settles (first recognition is otherwise slow).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.ocrEngine.prewarm()
        }
        performanceMonitor.startMonitoring()
        startStatsUpdateTimer()
        installKeyMonitor()
    }

    /// The old BufferManager dumped JPEG frames to tmp and kept its own
    /// recovery index; neither is used anymore.
    private static func removeLegacyBufferFiles() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: fileManager.temporaryDirectory.appendingPathComponent("SharpStreamBuffer", isDirectory: true))
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? fileManager.removeItem(at: appSupport.appendingPathComponent("SharpStream/buffer_index.json"))
        }
    }

    // MARK: - Preferences

    func applyPreferences() {
        let defaults = UserDefaults.standard
        if let algorithm = FocusAlgorithm(rawValue: defaults.string(forKey: UserDefaultsKey.focusAlgorithm) ?? ""),
           algorithm != focusScorer.algorithm {
            focusScorer.setAlgorithm(algorithm)
        }
        let ocrEnabled = defaults.bool(forKey: UserDefaultsKey.ocrEnabled)
        if ocrEngine.isEnabled != ocrEnabled { ocrEngine.isEnabled = ocrEnabled }
        let language = defaults.string(forKey: UserDefaultsKey.ocrLanguage) ?? ""
        let languages = language
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if ocrEngine.languages != languages { ocrEngine.languages = languages }
        let level = OCRRecognitionLevel(rawValue: defaults.string(forKey: UserDefaultsKey.ocrRecognitionLevel) ?? "") ?? .accurate
        if ocrEngine.recognitionLevel != level { ocrEngine.recognitionLevel = level }
        let correction = defaults.bool(forKey: UserDefaultsKey.ocrLanguageCorrection)
        if ocrEngine.usesLanguageCorrection != correction { ocrEngine.usesLanguageCorrection = correction }
    }

    // MARK: - Player binding

    private func bind(to player: MPVPlayerWrapper?) {
        playerCancellables.removeAll()
        clearAnalysis()
        guard let player else { return }

        // Resuming playback dismisses the frozen analyzed frame.
        player.$isPlaying
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.clearAnalysis() }
            .store(in: &playerCancellables)
    }

    private func clearAnalysis() {
        analyzedFrame = nil
        smartPauseSelection = nil
    }

    // MARK: - Status

    func showStatus(_ text: String, isError: Bool = false, duration: TimeInterval = 3.5) {
        statusMessage = StatusMessage(text: text, isError: isError)
        statusClearWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.statusMessage = nil }
        statusClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    // MARK: - Stats / QoS

    private func startStatsUpdateTimer() {
        statsUpdateTimer?.invalidate()
        statsUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStats() }
        }
    }

    private func updateStats() {
        var stats = streamManager.streamStats
        stats.cpuUsage = performanceMonitor.cpuUsage
        stats.memoryPressure = performanceMonitor.memoryPressure
        stats.currentFocusScore = focusScorer.getCurrentScore()
        stats.focusScoringFPS = focusScorer.getScoringFPS()
        stats.ramBufferUsage = focusScorer.retainedFrameBytes() / (1024 * 1024)
        stats.diskBufferUsage = 0
        if stats != streamManager.streamStats {
            streamManager.streamStats = stats
        }
        streamManager.updateSmartPauseQoS(
            pipelineLoad: player?.capturePipelineLoad(),
            memoryPressure: stats.memoryPressure
        )
    }

    // MARK: - Connecting

    func connect(to stream: SavedStream) {
        var stream = stream
        stream.url = stream.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if StreamProtocol.detect(from: stream.url) == .file {
            stream.url = fileAccess.beginAccess(for: stream.url)
        } else {
            fileAccess.endAccess()
        }
        streamManager.connect(to: stream)
    }

    func connect(urlString rawInput: String, name: String? = nil) {
        var urlString = Self.normalizeStreamInput(rawInput)
        guard !urlString.isEmpty else { return }
        // Sandbox access must be in place before validation checks the file exists.
        if StreamProtocol.detect(from: urlString) == .file {
            urlString = fileAccess.beginAccess(for: urlString)
        }
        let validation = StreamURLValidator.validate(urlString)
        guard validation.isValid else {
            showStatus(validation.errorMessage ?? "Invalid stream URL", isError: true)
            return
        }
        let stream = SavedStream(
            name: name ?? Self.defaultName(for: urlString),
            url: urlString,
            protocolType: StreamProtocol.detect(from: urlString)
        )
        connect(to: stream)
    }

    func openFile(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            showStatus("File not found: \(url.lastPathComponent)", isError: true)
            return
        }
        // The user just granted access (panel/drop): keep it for later launches.
        fileAccess.remember(url)
        let stream = SavedStream(name: url.lastPathComponent, url: url.absoluteString, protocolType: .file)
        connect(to: stream)
    }

    func presentOpenFilePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi, .mpeg2TransportStream]
        panel.message = "Select a video file to open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFile(url: url)
    }

    func pasteStreamURL() {
        guard let raw = NSPasteboard.general.string(forType: .string),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showStatus("The clipboard doesn't contain a stream URL.", isError: true)
            return
        }
        connect(urlString: raw)
    }

    func disconnect() {
        streamManager.disconnect()
        fileAccess.endAccess()
        currentOCRResult = nil
        clearAnalysis()
    }

    func checkForRecoverableSession() {
        guard !didCheckRecovery else { return }
        didCheckRecovery = true
        // Development/testing hook: launch straight into a stream.
        if let url = ProcessInfo.processInfo.environment["SHARPSTREAM_OPEN_URL"], !url.isEmpty {
            connect(urlString: url)
            return
        }
        guard !Self.isUITesting else { return }
        guard let recovery = recoveryStore.load() else { return }
        recoveryStore.clear()
        if ProcessInfo.processInfo.environment["SHARPSTREAM_DISABLE_BLOCKING_ALERTS"] == "1" { return }

        let alert = NSAlert()
        alert.messageText = "Resume Previous Stream?"
        alert.informativeText = "SharpStream quit unexpectedly while playing “\(recovery.streamName)”.\n\n\(StreamURLRedactor.redacted(recovery.streamURL))"
        alert.addButton(withTitle: "Resume")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            connect(urlString: recovery.streamURL, name: recovery.streamName)
        }
    }

    static func normalizeStreamInput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.absoluteString
        }
        return trimmed
    }

    static func defaultName(for urlString: String) -> String {
        if let url = URL(string: urlString) {
            if url.isFileURL { return url.lastPathComponent }
            if let host = url.host, !host.isEmpty { return host }
        }
        return "Stream"
    }

    // MARK: - Playback

    var seekMode: SeekMode { streamManager.seekMode }

    func togglePlayPause() {
        player?.togglePlayPause()
    }

    func seek(by offset: TimeInterval) {
        guard let player else { return }
        // The frozen frame no longer matches the video once it moves.
        clearAnalysis()
        switch seekMode {
        case .absolute:
            let target = max(0, min(player.duration, player.precisePlaybackTime + offset))
            player.seek(to: target, exact: false)
        case .liveBuffered:
            let lag = streamManager.liveDVRState.lagSeconds
            let window = streamManager.liveDVRState.windowSeconds
            let clamped = offset > 0
                ? StreamManager.clampLiveSeekOffset(offset, lagSeconds: lag)
                : max(offset, -(window - lag))
            guard abs(clamped) > 0.1 else {
                showStatus(offset > 0 ? "Already at the live edge." : "Start of the buffer reached.")
                return
            }
            if !player.seek(offset: clamped, exact: false) {
                showStatus("Seek failed for this stream.", isError: true)
            }
        case .disabled:
            showStatus("This source can't seek.")
        }
    }

    func seek(toTimelinePosition position: TimeInterval, exact: Bool) {
        guard let player else { return }
        clearAnalysis()
        switch seekMode {
        case .absolute:
            player.seek(to: max(0, min(position, player.duration)), exact: exact)
        case .liveBuffered:
            streamManager.seekLive(toWindowPosition: position)
        case .disabled:
            break
        }
    }

    func stepFrame(backward: Bool) {
        guard seekMode == .absolute else { return }
        clearAnalysis()
        player?.stepFrame(backward: backward)
    }

    func jumpToLive() {
        clearAnalysis()
        if !streamManager.seekToLiveEdge() {
            showStatus("Live edge unavailable.")
        }
    }

    func setSpeed(_ speed: Double) {
        player?.setSpeed(speed)
    }

    func setVolume(_ volume: Double) {
        player?.setVolume(volume)
        // Remembered for the next stream / launch.
        UserDefaults.standard.set(max(0, min(1, volume)), forKey: UserDefaultsKey.playbackVolume)
    }

    func clearRecentStreams() {
        streamDatabase.clearRecentStreams()
        NotificationCenter.default.post(name: .recentStreamsUpdated, object: nil)
        showStatus("Recent streams cleared.")
    }

    // MARK: - Smart Pause & OCR

    func smartPause() {
        guard !isPerformingSmartPause else { return }
        guard let player else {
            showStatus("Connect to a stream first.", isError: true)
            return
        }
        isPerformingSmartPause = true
        Task {
            defer { isPerformingSmartPause = false }
            let defaults = UserDefaults.standard
            let result = await smartPauseCoordinator.perform(
                request: SmartPauseRequest(
                    lookbackSeconds: defaults.double(forKey: UserDefaultsKey.lookbackWindow),
                    seekMode: seekMode,
                    currentPlaybackTime: player.precisePlaybackTime,
                    autoOCREnabled: defaults.bool(forKey: UserDefaultsKey.autoOCROnSmartPause)
                ),
                player: player
            )
            lastSmartPauseDiagnostics = result.diagnostics
            showStatus(result.statusMessage, isError: !result.isSuccess)
            guard result.isSuccess else { return }

            smartPauseSelection = result.selection
            isPerformingSmartPause = false
            if let pixelBuffer = result.selectedPixelBuffer {
                present(pixelBuffer, playbackTime: result.selection?.playbackTime)
                if result.shouldRunOCR {
                    await runOCR(on: pixelBuffer, announce: false)
                }
            }
        }
    }

    /// Pause and recognize text in the frame on screen (or the frozen analyzed frame).
    func recognizeText() {
        guard !isRecognizingText else { return }
        Task { _ = await recognizeTextNow() }
    }

    @discardableResult
    private func recognizeTextNow() async -> OCRResult? {
        guard ocrEngine.isEnabled else {
            showStatus("OCR is turned off in Settings › OCR.", isError: true)
            return nil
        }
        guard let pixelBuffer = await frameForAnalysis(pause: true) else {
            showStatus("No video frame available.", isError: true)
            return nil
        }
        return await runOCR(on: pixelBuffer, announce: true)
    }

    @discardableResult
    private func runOCR(on pixelBuffer: CVPixelBuffer, announce: Bool) async -> OCRResult? {
        ocrRunsInFlight += 1
        isRecognizingText = true
        defer {
            ocrRunsInFlight -= 1
            isRecognizingText = ocrRunsInFlight > 0
        }
        let result = await ocrEngine.recognizeText(in: pixelBuffer)
        // The user may have resumed playback while OCR was running.
        guard let frame = analyzedFrame, frame.pixelBuffer === pixelBuffer else { return result }
        analyzedFrame?.ocrResult = result ?? OCRResult(text: "", confidence: 0)
        currentOCRResult = result
        if result != nil, UserDefaults.standard.bool(forKey: UserDefaultsKey.autoShowTextPanel) {
            showOCRInspector = true
        }
        if let result {
            if showOCRInspector == false, announce {
                showStatus("Recognized \(result.lines.count) line(s). Open the Text panel to review.")
            } else if announce {
                showStatus("Recognized \(result.lines.count) line(s).")
            }
        } else if announce {
            showStatus("No text found in this frame.")
        }
        return result
    }

    /// The frame currently frozen on screen, or a fresh capture of the video.
    private func frameForAnalysis(pause: Bool) async -> CVPixelBuffer? {
        if let frame = analyzedFrame {
            return frame.pixelBuffer
        }
        guard let player else { return nil }
        if pause { player.pause() }
        let time = player.precisePlaybackTime
        guard let pixelBuffer = await player.captureFrame() else { return nil }
        // Playback may have resumed (or the player changed) during the capture.
        if pause, self.player === player, !player.isPlaying {
            present(pixelBuffer, playbackTime: time)
        }
        return pixelBuffer
    }

    private func present(_ pixelBuffer: CVPixelBuffer, playbackTime: TimeInterval?) {
        guard let image = exportManager.cgImage(from: pixelBuffer) else { return }
        analyzedFrame = AnalyzedFrame(pixelBuffer: pixelBuffer, image: image, playbackTime: playbackTime, ocrResult: nil)
    }

    func dismissAnalysis() {
        clearAnalysis()
    }

    // MARK: - Copy / export

    func copyOCRText() {
        Task {
            var result = analyzedFrame?.ocrResult ?? (analyzedFrame == nil ? nil : currentOCRResult)
            if result == nil || result?.text.isEmpty == true {
                result = await recognizeTextNow()
            }
            guard let text = result?.text, !text.isEmpty else { return }
            exportManager.copyTextToClipboard(text)
            showStatus("Copied \(text.count) characters.")
        }
    }

    func copyText(_ text: String) {
        exportManager.copyTextToClipboard(text)
        showStatus("Copied “\(text.prefix(40))\(text.count > 40 ? "…" : "")”")
    }

    func copyFrame() {
        Task {
            guard let frame = await frameForAnalysis(pause: false) else {
                showStatus("No video frame available.", isError: true)
                return
            }
            exportManager.copyFrameToClipboard(frame)
            showStatus("Frame copied to the clipboard.")
        }
    }

    func saveFrameAs() {
        Task {
            guard let frame = await frameForAnalysis(pause: false) else {
                showStatus("No video frame available.", isError: true)
                return
            }
            guard let url = runSavePanel(defaultName: "frame-\(Self.timestampString())", types: [.png, .jpeg]) else { return }
            do {
                try exportManager.saveFrame(frame, to: url, format: exportFormat(for: url))
                rememberExportDirectory(url)
                showStatus("Saved \(url.lastPathComponent)")
            } catch {
                showStatus("Save failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func quickSaveFrame() {
        Task {
            guard let frame = await frameForAnalysis(pause: false) else {
                showStatus("No video frame available.", isError: true)
                return
            }
            let format = defaultExportFormat
            do {
                let url = try fileAccess.withQuickSaveFolder { folder -> URL in
                    let url = Self.uniqueURL(in: folder, base: "frame-\(Self.timestampString())", ext: format.fileExtension)
                    try exportManager.saveFrame(frame, to: url, format: format)
                    return url
                }
                showStatus("Saved \(url.lastPathComponent) to \(url.deletingLastPathComponent().lastPathComponent)")
            } catch {
                showStatus("Quick save failed: \(error.localizedDescription). Choose a folder in Settings › Export.", isError: true)
            }
        }
    }

    func exportOCRText() {
        guard let text = (analyzedFrame?.ocrResult ?? currentOCRResult)?.text, !text.isEmpty else {
            showStatus("Run text recognition first (⌘R).", isError: true)
            return
        }
        guard let url = runSavePanel(defaultName: "ocr-\(Self.timestampString()).txt", types: [.plainText]) else { return }
        do {
            try exportManager.exportOCRText(text, to: url)
            showStatus("Exported \(url.lastPathComponent)")
        } catch {
            showStatus("Export failed: \(error.localizedDescription)", isError: true)
        }
    }

    func exportFrameWithOCR() {
        Task {
            var result = analyzedFrame?.ocrResult
            if result == nil || result?.lines.isEmpty == true {
                result = await recognizeTextNow()
            }
            guard let frame = analyzedFrame?.pixelBuffer, let result, !result.lines.isEmpty else { return }
            guard let url = runSavePanel(defaultName: "frame-ocr-\(Self.timestampString())", types: [.png, .jpeg]) else { return }
            do {
                try exportManager.exportFrameWithOCR(frame, ocrResult: result, to: url, format: exportFormat(for: url))
                rememberExportDirectory(url)
                showStatus("Exported \(url.lastPathComponent)")
            } catch {
                showStatus("Export failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private var defaultExportFormat: ExportFormat {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: UserDefaultsKey.defaultExportFormat) == "JPEG" {
            return .jpeg(quality: CGFloat(defaults.double(forKey: UserDefaultsKey.defaultJPEGQuality)))
        }
        return .png
    }

    private func exportFormat(for url: URL) -> ExportFormat {
        let ext = url.pathExtension.lowercased()
        if ext == "jpg" || ext == "jpeg" {
            return .jpeg(quality: CGFloat(UserDefaults.standard.double(forKey: UserDefaultsKey.defaultJPEGQuality)))
        }
        return .png
    }

    /// Initial folder for save panels (panels can open anywhere; this is only a
    /// starting location, not a grant of access).
    private var lastExportDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: UserDefaultsKey.lastFrameExportDirectory),
           !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileAccessStore.downloadsFolder
    }

    func chooseQuickSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Quick Save puts frames"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try fileAccess.rememberQuickSaveFolder(url)
        } catch {
            showStatus("Couldn't use that folder: \(error.localizedDescription)", isError: true)
        }
    }

    func resetQuickSaveFolder() {
        fileAccess.resetQuickSaveFolder()
    }

    private static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)-\(index).\(ext)")
            index += 1
        }
        return url
    }

    private func rememberExportDirectory(_ fileURL: URL) {
        UserDefaults.standard.set(fileURL.deletingLastPathComponent().path, forKey: UserDefaultsKey.lastFrameExportDirectory)
    }

    private func runSavePanel(defaultName: String, types: [UTType]) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = types
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.directoryURL = lastExportDirectory
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - Keyboard

    /// Windows whose unmodified Space / arrow keys control playback.
    func registerPlayerWindow(_ window: NSWindow) {
        playerWindows.add(window)
    }

    /// Space / arrow shortcuts are handled here rather than as menu key
    /// equivalents: menu equivalents fire *before* text fields see the key, which
    /// made it impossible to type a space or move the caret in any text field.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleKeyDown(event) ? nil : event }
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window = event.window, playerWindows.contains(window),
              window.attachedSheet == nil,
              player != nil else { return false }
        if let responder = window.firstResponder, responder is NSText || responder is NSTextField {
            return false
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Punctuation by character so it works on non-US layouts.
        if modifiers.isEmpty, let characters = event.charactersIgnoringModifiers {
            if characters == "," { stepFrame(backward: true); return true }
            if characters == "." { stepFrame(backward: false); return true }
        }
        switch (event.keyCode, modifiers) {
        case (49, []): // space
            togglePlayPause()
        case (123, []): // left
            seekMode == .absolute && !(player?.isPlaying ?? true) ? stepFrame(backward: true) : seek(by: -5)
        case (124, []): // right
            seekMode == .absolute && !(player?.isPlaying ?? true) ? stepFrame(backward: false) : seek(by: 5)
        case (123, [.command]):
            seek(by: -10)
        case (124, [.command]):
            seek(by: 10)
        case (53, []): // escape
            guard analyzedFrame != nil else { return false }
            dismissAnalysis()
        default:
            return false
        }
        return true
    }
}

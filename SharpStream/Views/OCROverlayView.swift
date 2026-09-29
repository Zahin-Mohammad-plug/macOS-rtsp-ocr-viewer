//
//  OCROverlayView.swift
//  SharpStream
//
//  Frozen analyzed frame with OCR boxes, and the recognized-text inspector.
//
//  The overlay draws the exact frame that was scored/recognized, aspect-fit
//  into the same rect as the video. Boxes are mapped against that image, so
//  they line up at any window size and don't depend on where the underlying
//  player landed after a seek.
//

import SwiftUI

struct AnalyzedFrameOverlay: View {
    @EnvironmentObject var appState: AppState
    @AppStorage(UserDefaultsKey.ocrOverlayShowBoxes) private var showBoxes = true
    @AppStorage(UserDefaultsKey.ocrOverlayShowText) private var showLabels = true
    let frame: AnalyzedFrame
    @State private var hoveredLineID: UUID?

    var body: some View {
        GeometryReader { geometry in
            let videoRect = VideoLayoutMapper.videoRect(container: geometry.size, source: frame.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: videoRect.width, height: videoRect.height)
                    .position(x: videoRect.midX, y: videoRect.midY)

                if showBoxes, let result = frame.ocrResult {
                    ForEach(result.lines) { line in
                        box(for: line, in: videoRect)
                    }
                }

                header
                    .frame(width: max(0, videoRect.width - 16), alignment: .leading)
                    .position(x: videoRect.midX, y: videoRect.minY + 22)
            }
        }
        .accessibilityIdentifier("analyzedFrameOverlay")
    }

    @ViewBuilder
    private func box(for line: OCRLine, in videoRect: CGRect) -> some View {
        let rect = VideoLayoutMapper.mapVisionBox(line.boundingBox, in: videoRect).insetBy(dx: -2, dy: -2)
        let isHovered = hoveredLineID == line.id

        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(isHovered ? Color.yellow : Color.green, lineWidth: isHovered ? 3 : 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.green.opacity(isHovered ? 0.18 : 0.06)))
            .frame(width: max(rect.width, 4), height: max(rect.height, 4))
            .position(x: rect.midX, y: rect.midY)
            .onHover { hovering in hoveredLineID = hovering ? line.id : (hoveredLineID == line.id ? nil : hoveredLineID) }
            .onTapGesture { appState.copyText(line.text) }
            .help("\(line.text)\nClick to copy")

        if showLabels, isHovered {
            Text(line.text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.white)
                .fixedSize()
                .position(x: rect.midX, y: max(videoRect.minY + 10, rect.minY - 11))
                .allowsHitTesting(false)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(headerText, systemImage: "pause.rectangle")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
            Spacer()
            Button {
                appState.dismissAnalysis()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .padding(6)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss analyzed frame (Esc)")
        }
    }

    private var headerText: String {
        guard let result = frame.ocrResult else { return "Analyzed frame" }
        return result.lines.isEmpty ? "No text found" : "\(result.lines.count) text region\(result.lines.count == 1 ? "" : "s") · click to copy"
    }
}

struct OCRInspectorView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var streamManager: StreamManager

    private var result: OCRResult? {
        appState.analyzedFrame?.ocrResult ?? appState.currentOCRResult
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recognized Text")
                    .font(.headline)
                Spacer()
                if appState.isRecognizingText {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if let result, !result.lines.isEmpty {
                List(result.lines) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.text)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        // Accurate mode reports ~100% for most lines; only flag doubtful ones.
                        if line.confidence < 0.9 {
                            Label("\(Int((line.confidence * 100).rounded()))% confidence", systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .contextMenu {
                        Button("Copy Line") { appState.copyText(line.text) }
                    }
                }
                .listStyle(.inset)

                Divider()
                HStack {
                    Button("Copy All") { appState.copyText(result.text) }
                    Spacer()
                    Menu {
                        Button("Export Text…") { appState.exportOCRText() }
                        Button("Export Frame with Boxes…") { appState.exportFrameWithOCR() }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .fixedSize()
                }
                .padding(10)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(result == nil ? "No text recognized yet" : "No text found in this frame")
                        .font(.callout.weight(.medium))
                    Text("Use Smart Pause (⌘S) to freeze the sharpest recent frame, or Recognize Text (⌘R) on the current frame.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Recognize Text") { appState.recognizeText() }
                        .disabled(streamManager.player == nil || appState.isRecognizingText)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("ocrInspector")
    }
}

struct BufferingIndicator: View {
    @ObservedObject var player: MPVPlayerWrapper

    var body: some View {
        if player.isBuffering {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Buffering…").font(.callout)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
        }
    }
}

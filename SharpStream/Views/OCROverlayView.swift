//
//  OCROverlayView.swift
//  SharpStream
//
//  Text overlay on video frame
//

import SwiftUI

struct OCROverlayView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentOCRResult: OCRResult?
    @AppStorage("ocrOverlayShowText") private var showOCRTextOverlay: Bool = false
    @AppStorage("ocrOverlayShowBoxes") private var showBoundingBoxes: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let containerSize = geometry.size
            let sourceSize = appState.streamManager.streamStats.resolution ?? containerSize
            let mappedVideoRect = VideoLayoutMapper.videoRect(container: containerSize, source: sourceSize)
            let isPlaying = appState.streamManager.player?.isPlaying ?? false

            ZStack(alignment: .topLeading) {
                if !isPlaying, let result = currentOCRResult, showBoundingBoxes {
                    ForEach(Array(result.boundingBoxes.enumerated()), id: \.offset) { _, boundingBox in
                        let mappedRect = VideoLayoutMapper.mapVisionBox(boundingBox, in: mappedVideoRect)
                        Rectangle()
                            .stroke(Color.green, lineWidth: 2)
                            .frame(width: mappedRect.width, height: mappedRect.height)
                            .position(x: mappedRect.midX, y: mappedRect.midY)
                    }
                }

                overlayControls(videoRect: mappedVideoRect)

                if !isPlaying,
                   let result = currentOCRResult,
                   showOCRTextOverlay,
                   !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack {
                        Spacer()

                        ScrollView {
                            Text(result.text)
                                .padding()
                                .background(Color.black.opacity(0.7))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                                .textSelection(.enabled)
                                .onTapGesture {
                                    appState.exportManager.copyTextToClipboard(result.text)
                                }
                        }
                        .frame(maxHeight: min(220, mappedVideoRect.height * 0.45))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
                    .frame(width: mappedVideoRect.width, height: mappedVideoRect.height, alignment: .bottom)
                    .position(x: mappedVideoRect.midX, y: mappedVideoRect.midY)
                }
            }
        }
        .onAppear {
            currentOCRResult = appState.currentOCRResult
        }
        .onChange(of: appState.currentOCRResult) { _, newValue in
            currentOCRResult = newValue
        }
    }

    @ViewBuilder
    private func overlayControls(videoRect: CGRect) -> some View {
        VStack {
            HStack {
                Spacer()
                Menu {
                    Toggle("Show OCR Text", isOn: $showOCRTextOverlay)
                    Toggle("Show Bounding Boxes", isOn: $showBoundingBoxes)
                } label: {
                    Image(systemName: "text.viewfinder")
                        .padding(8)
                        .background(Color.black.opacity(0.55))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                }
            }
            Spacer()
        }
        .frame(width: videoRect.width, height: videoRect.height, alignment: .topLeading)
        .position(x: videoRect.midX, y: videoRect.midY)
        .padding(.top, 8)
        .padding(.horizontal, 8)
    }
}

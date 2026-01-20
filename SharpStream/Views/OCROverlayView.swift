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
    @State private var showBoundingBoxes = false
    
    var body: some View {
        ZStack {
            // Bounding boxes overlay (if enabled)
            if let result = currentOCRResult, showBoundingBoxes {
                GeometryReader { geometry in
                    ForEach(Array(result.boundingBoxes.enumerated()), id: \.offset) { index, boundingBox in
                        Rectangle()
                            .stroke(Color.green, lineWidth: 2)
                            .frame(
                                width: boundingBox.width * geometry.size.width,
                                height: boundingBox.height * geometry.size.height
                            )
                            .position(
                                x: (boundingBox.midX * geometry.size.width),
                                y: geometry.size.height - (boundingBox.midY * geometry.size.height)
                            )
                    }
                }
            }
            
            // Text overlay
            if let result = currentOCRResult, !result.text.isEmpty {
                VStack {
                    // Toggle button for bounding boxes
                    HStack {
                        Spacer()
                        Button(action: { showBoundingBoxes.toggle() }) {
                            Image(systemName: showBoundingBoxes ? "eye.fill" : "eye.slash.fill")
                                .padding(8)
                                .background(Color.black.opacity(0.5))
                                .foregroundColor(.white)
                                .cornerRadius(4)
                        }
                        .padding()
                    }
                    
                    Spacer()
                    
                    ScrollView {
                        Text(result.text)
                            .padding()
                            .background(Color.black.opacity(0.7))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .textSelection(.enabled)
                            .onTapGesture {
                                // Copy to clipboard
                                appState.exportManager.copyTextToClipboard(result.text)
                            }
                    }
                    .frame(maxHeight: 200)
                    .padding()
                }
            }
        }
        .onChange(of: appState.currentOCRResult) { _, newValue in
            currentOCRResult = newValue
        }
    }
}

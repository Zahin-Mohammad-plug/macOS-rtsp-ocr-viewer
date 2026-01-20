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
        if let result = currentOCRResult, !result.text.isEmpty {
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
                            // Copy to clipboard
                            appState.exportManager.copyTextToClipboard(result.text)
                        }
                }
                .frame(maxHeight: 200)
                .padding()
            }
        }
    }
}

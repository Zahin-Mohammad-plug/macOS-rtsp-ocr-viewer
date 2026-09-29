//
//  StreamConfigurationView.swift
//  SharpStream
//
//  Modal sheet for adding/editing streams
//

import SwiftUI

struct StreamConfigurationView: View {
    @Environment(\.dismiss) var dismiss
    let stream: SavedStream?
    let onSave: (SavedStream) -> Void
    
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var validationResult: ValidationResult?
    @State private var isTestingConnection = false
    @State private var connectionTestResult: ConnectionTestResult?
    
    var body: some View {
        VStack(spacing: 20) {
            Text(stream == nil ? "Add Stream" : "Edit Stream")
                .font(.title2)
                .padding()
            
            Form {
                TextField("Stream Name", text: $name)
                    .accessibilityIdentifier("streamNameField")
                    .onChange(of: name) { _, _ in
                        validate()
                    }
                
                TextField("Stream URL", text: $url)
                    .accessibilityIdentifier("streamURLField")
                    .onChange(of: url) { _, _ in
                        // A previous test result doesn't apply to an edited URL.
                        connectionTestResult = nil
                        validate()
                    }
                
                if let result = validationResult, !result.isValid {
                    Text(result.errorMessage ?? "Invalid URL")
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                if let result = connectionTestResult {
                    Text(result.errorMessage)
                        .foregroundColor(connectionResultColor(result))
                        .font(.caption)
                }
            }
            .padding()
            
            HStack {
                Button("Test Connection") {
                    testConnection()
                }
                .disabled(url.isEmpty || validationResult?.isValid != true || isTestingConnection)
                
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || url.isEmpty || validationResult?.isValid != true)
            }
            .padding()
        }
        .frame(width: 500, height: 300)
        .onAppear {
            if let stream = stream {
                name = stream.name
                url = stream.url
            }
            validate()
        }
    }
    
    private func validate() {
        validationResult = StreamURLValidator.validate(url)
    }
    
    private func testConnection() {
        isTestingConnection = true
        Task {
            let result = await StreamURLValidator.testConnection(to: url)
            await MainActor.run {
                connectionTestResult = result
                isTestingConnection = false
            }
        }
    }
    
    private func save() {
        guard validationResult?.isValid == true else {
            return
        }
        
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedStream = SavedStream(
            id: stream?.id ?? UUID(),
            name: trimmedName.isEmpty ? AppState.defaultName(for: trimmedURL) : trimmedName,
            url: trimmedURL,
            protocolType: StreamProtocol.detect(from: trimmedURL),
            // Editing must not reset when the stream was added or last used.
            createdAt: stream?.createdAt ?? Date(),
            lastUsed: stream?.lastUsed
        )
        
        onSave(savedStream)
    }

    private func connectionResultColor(_ result: ConnectionTestResult) -> Color {
        switch result {
        case .success:
            return .green
        case .waitingForInboundCaller:
            return .orange
        default:
            return .red
        }
    }
}

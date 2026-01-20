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
                    .onChange(of: name) { _ in
                        validate()
                    }
                
                TextField("Stream URL", text: $url)
                    .onChange(of: url) { _ in
                        validate()
                    }
                
                if let result = validationResult, !result.isValid {
                    Text(result.errorMessage ?? "Invalid URL")
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                if let result = connectionTestResult {
                    Text(result.errorMessage)
                        .foregroundColor(result == ConnectionTestResult.success ? .green : .red)
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
        
        let protocolType = StreamProtocol.detect(from: url)
        let savedStream = SavedStream(
            id: stream?.id ?? UUID(),
            name: name,
            url: url,
            protocolType: protocolType
        )
        
        onSave(savedStream)
    }
}

//
//  StatsPanel.swift
//  SharpStream
//
//  Connection & buffer statistics with performance monitoring
//

import SwiftUI

struct StatsPanel: View {
    @EnvironmentObject var appState: AppState
    @State private var stats = StreamStats()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Statistics")
                .font(.headline)
            
            Divider()
            
            // Connection Status
            StatRow(label: "Status", value: connectionStatusText(stats.connectionStatus))
            
            // Stream Info
            if let bitrate = stats.bitrate {
                StatRow(label: "Bitrate", value: formatBitrate(bitrate))
            }
            
            if let resolution = stats.resolution {
                StatRow(label: "Resolution", value: "\(Int(resolution.width))×\(Int(resolution.height))")
            }
            
            if let frameRate = stats.frameRate {
                StatRow(label: "Frame Rate", value: String(format: "%.2f fps", frameRate))
            }
            
            // Buffer Info
            StatRow(label: "Buffer Duration", value: formatTime(stats.bufferDuration))
            StatRow(label: "RAM Buffer", value: "\(stats.ramBufferUsage) MB")
            StatRow(label: "Disk Buffer", value: "\(stats.diskBufferUsage) MB")
            
            // Focus Score
            if let focusScore = stats.currentFocusScore {
                StatRow(label: "Focus Score", value: String(format: "%.2f", focusScore))
            }
            
            Divider()
            
            // Performance Monitoring
            Text("Performance")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if let cpuUsage = stats.cpuUsage {
                StatRow(label: "CPU Usage", value: String(format: "%.1f%%", cpuUsage))
            }
            
            if let gpuUsage = stats.gpuUsage {
                StatRow(label: "GPU Usage", value: String(format: "%.1f%%", gpuUsage))
            }
            
            if let scoringFPS = stats.focusScoringFPS {
                StatRow(label: "Focus Scoring FPS", value: String(format: "%.1f", scoringFPS))
            }

            StatRow(
                label: "Smart Pause Sampling",
                value: appState.streamManager.smartPauseSamplingTier.displayName
            )
            
            StatRow(label: "Memory Pressure", value: stats.memoryPressure.rawValue)
        }
        .padding()
        .frame(maxWidth: 300)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .onReceive(appState.streamManager.$streamStats) { newStats in
            stats = newStats
        }
    }
    
    private func connectionStatusText(_ status: ConnectionState) -> String {
        switch status {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .reconnecting:
            return "Reconnecting..."
        case .error(let message):
            return "Error: \(message)"
        }
    }
    
    private func formatBitrate(_ bitsPerSecond: Int) -> String {
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.2f Mbps", Double(bitsPerSecond) / 1_000_000.0)
        } else if bitsPerSecond >= 1_000 {
            return String(format: "%.2f Kbps", Double(bitsPerSecond) / 1_000.0)
        } else {
            return "\(bitsPerSecond) bps"
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

struct StatRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label + ":")
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.caption)
    }
}

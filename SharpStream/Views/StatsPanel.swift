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
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Statistics")
                    .font(.headline)

                Divider()

                // Connection Status
                StatRow(label: "Status", value: connectionStatusText(stats.connectionStatus))

                Text("Stream Health")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                StatRow(label: "Health", value: stats.streamHealth.rawValue)
                StatRow(label: "Health Reason", value: stats.streamHealthReason ?? "N/A")

                Divider()

                Text("Transport")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                StatRow(
                    label: "Current Bitrate",
                    value: stats.bitrate.map(formatBitrate) ?? "N/A",
                    valueIdentifier: "statCurrentBitrateValue"
                )
                StatRow(
                    label: "RX Rate",
                    value: stats.rxRateBps.map(formatByteRate) ?? "N/A",
                    valueIdentifier: "statRxRateValue"
                )
                StatRow(
                    label: "Buffer Level",
                    value: stats.bufferLevelSeconds.map(formatSeconds) ?? "N/A",
                    valueIdentifier: "statBufferLevelValue"
                )
                StatRow(
                    label: "Jitter (Proxy)",
                    value: stats.jitterProxyMs.map { String(format: "%.0f ms", $0) } ?? "N/A",
                    valueIdentifier: "statJitterProxyValue"
                )
                StatRow(
                    label: "Packet Loss (Proxy)",
                    value: stats.packetLossProxyPct.map { String(format: "%.1f%%", $0) } ?? "N/A",
                    valueIdentifier: "statPacketLossProxyValue"
                )

                Divider()

                Text("Video")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                StatRow(
                    label: "Resolution",
                    value: stats.resolution.map { "\(Int($0.width))×\(Int($0.height))" } ?? "N/A",
                    valueIdentifier: "statResolutionValue"
                )
                StatRow(
                    label: "Frame Rate",
                    value: stats.frameRate.map { String(format: "%.2f fps", $0) } ?? "N/A",
                    valueIdentifier: "statFrameRateValue"
                )
                StatRow(
                    label: "Codec",
                    value: stats.codecName?.uppercased() ?? "N/A",
                    valueIdentifier: "statCodecValue"
                )
                StatRow(
                    label: "Keyframe Interval",
                    value: stats.keyframeIntervalSeconds.map { String(format: "%.2f s", $0) } ?? "N/A",
                    valueIdentifier: "statKeyframeIntervalValue"
                )

                Divider()

                Text("Network / Wi-Fi")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                StatRow(label: "RTT (SRT)", value: stats.rttMs.map { String(format: "%.0f ms", $0) } ?? "N/A (phase 2)")
                StatRow(
                    label: "Packet Loss (SRT)",
                    value: stats.packetLossPct.map { String(format: "%.1f%%", $0) } ?? "N/A (phase 2)"
                )
                StatRow(label: "RSSI", value: "N/A (phase 2)")

                Divider()

                Text("Buffer & Performance")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                StatRow(label: "Buffer Duration", value: formatTime(stats.bufferDuration))
                StatRow(label: "RAM Buffer", value: "\(stats.ramBufferUsage) MB")
                StatRow(label: "Disk Buffer", value: "\(stats.diskBufferUsage) MB")

                if let focusScore = stats.currentFocusScore {
                    StatRow(label: "Focus Score", value: String(format: "%.2f", focusScore))
                }
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
        }
        .accessibilityIdentifier("statsPanel")
        .background(Color(NSColor.windowBackgroundColor))
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

    private func formatByteRate(_ bytesPerSecond: Int) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.2f MB/s", Double(bytesPerSecond) / 1_000_000.0)
        } else if bytesPerSecond >= 1_000 {
            return String(format: "%.2f KB/s", Double(bytesPerSecond) / 1_000.0)
        } else {
            return "\(bytesPerSecond) B/s"
        }
    }

    private func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.2f s", seconds)
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
    var valueIdentifier: String?
    
    var body: some View {
        HStack {
            Text(label + ":")
                .foregroundColor(.secondary)
            Spacer()
            if let valueIdentifier {
                Text(value)
                    .fontWeight(.medium)
                    .accessibilityIdentifier(valueIdentifier)
            } else {
                Text(value)
                    .fontWeight(.medium)
            }
        }
        .font(.caption)
    }
}

struct StatisticsWindowView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        StatsPanel()
            .frame(minWidth: 380, minHeight: 560)
            .accessibilityIdentifier("statsPanel")
    }
}

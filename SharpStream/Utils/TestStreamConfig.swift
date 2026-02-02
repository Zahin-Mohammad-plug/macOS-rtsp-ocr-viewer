//
//  TestStreamConfig.swift
//  SharpStream
//
//  Env-driven stream configuration for local/CI testing.
//

import Foundation

struct TestStreamConfig {
    static let primaryRTSPEnvKey = "SHARPSTREAM_TEST_RTSP_URL"
    static let videoFileEnvKey = "SHARPSTREAM_TEST_VIDEO_FILE"
    static let streamsEnvKey = "SHARPSTREAM_TEST_STREAMS"

    let primaryRTSPURL: String?
    let videoFilePath: String?
    let streamList: [String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let primary = environment[Self.primaryRTSPEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let videoFile = environment[Self.videoFileEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = environment[Self.streamsEnvKey]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        self.primaryRTSPURL = (primary?.isEmpty == false) ? primary : nil
        self.videoFilePath = (videoFile?.isEmpty == false) ? videoFile : nil
        self.streamList = list
    }

    var preferredStreamForSmokeTests: String? {
        if let primaryRTSPURL {
            return primaryRTSPURL
        }
        if let videoFilePath {
            return "file://\(videoFilePath)"
        }
        return streamList.first
    }
}

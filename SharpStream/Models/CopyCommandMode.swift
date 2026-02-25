//
//  CopyCommandMode.swift
//  SharpStream
//
//  Cmd+C copy target selection
//

import Foundation

enum CopyCommandMode: String, CaseIterable, Codable {
    case ocrText
    case frame

    var label: String {
        switch self {
        case .ocrText: return "Text"
        case .frame: return "Frame"
        }
    }

    var menuLabel: String {
        switch self {
        case .ocrText: return "Copy OCR Text"
        case .frame: return "Copy Frame"
        }
    }
}

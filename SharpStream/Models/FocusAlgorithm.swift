//
//  FocusAlgorithm.swift
//  SharpStream
//
//  Focus scoring algorithm selection
//

import Foundation

enum FocusAlgorithm: String, CaseIterable {
    case laplacian = "Laplacian"
    case tenengrad = "Tenengrad"
    case sobel = "Sobel"
    
    var displayName: String {
        return rawValue
    }
}

//
//  PerformanceMonitor.swift
//  SharpStream
//
//  CPU/GPU usage and performance monitoring
//

import Foundation
import AppKit
import Darwin

class PerformanceMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0.0
    @Published var gpuUsage: Double = 0.0
    @Published var memoryPressure: MemoryPressureLevel = .normal
    
    private var monitoringTimer: Timer?
    
    func startMonitoring() {
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateMetrics()
        }
    }
    
    func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
    }
    
    private func updateMetrics() {
        cpuUsage = getCPUUsage()
        gpuUsage = getGPUUsage()
        memoryPressure = getMemoryPressure()
    }
    
    private func getCPUUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            // Simplified CPU usage calculation
            // In production, use more sophisticated method
            return Double(info.resident_size) / 1_000_000_000.0 * 100.0 // Rough estimate
        }
        
        return 0.0
    }
    
    private func getGPUUsage() -> Double {
        // GPU usage monitoring requires Metal Performance Shaders or IOKit
        // This is a placeholder - would need actual GPU monitoring implementation
        return 0.0
    }
    
    private func getMemoryPressure() -> MemoryPressureLevel {
        let processInfo = ProcessInfo.processInfo
        // Check system memory pressure
        // This is simplified - in production, use proper memory pressure API
        let memoryUsage = getMemoryUsage()
        
        if memoryUsage > 0.9 {
            return .critical
        } else if memoryUsage > 0.7 {
            return .warning
        } else {
            return .normal
        }
    }
    
    private func getMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let totalMemory = ProcessInfo.processInfo.physicalMemory
            return Double(info.resident_size) / Double(totalMemory)
        }
        
        return 0.0
    }
}

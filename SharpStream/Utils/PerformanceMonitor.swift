//
//  PerformanceMonitor.swift
//  SharpStream
//
//  CPU/GPU usage and performance monitoring
//

import Foundation
import AppKit
import Darwin
import Combine

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
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let task = mach_task_self_

        let result = task_threads(task, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threadList = threadList else {
            return 0.0
        }

        defer {
            let byteCount = vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.stride)
            vm_deallocate(task, vm_address_t(bitPattern: threadList), byteCount)
        }

        var totalCPUUsage: Double = 0
        for index in 0..<Int(threadCount) {
            var threadInfo = thread_basic_info()
            var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)

            let infoResult = withUnsafeMutablePointer(to: &threadInfo) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) {
                    thread_info(threadList[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                }
            }

            guard infoResult == KERN_SUCCESS else { continue }
            if (threadInfo.flags & TH_FLAGS_IDLE) == 0 {
                totalCPUUsage += (Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0
            }
        }

        return totalCPUUsage
    }
    
    private func getGPUUsage() -> Double {
        // GPU usage monitoring requires Metal Performance Shaders or IOKit
        // This is a placeholder - would need actual GPU monitoring implementation
        return 0.0
    }
    
    private func getMemoryPressure() -> MemoryPressureLevel {
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

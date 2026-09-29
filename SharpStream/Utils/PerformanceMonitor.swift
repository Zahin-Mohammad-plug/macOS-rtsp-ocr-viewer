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
    @Published var memoryPressure: MemoryPressureLevel = .normal
    
    private var monitoringTimer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var systemPressure: MemoryPressureLevel = .normal

    func startMonitoring() {
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMetrics() }
        }
        // The kernel's own signal for system-wide memory pressure.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            MainActor.assumeIsolated {
                if event.contains(.critical) {
                    self?.systemPressure = .critical
                } else if event.contains(.warning) {
                    self?.systemPressure = .warning
                } else {
                    self?.systemPressure = .normal
                }
            }
        }
        source.resume()
        pressureSource = source
    }

    func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        pressureSource?.cancel()
        pressureSource = nil
    }
    
    private func updateMetrics() {
        cpuUsage = getCPUUsage()
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
    
    
    private func getMemoryPressure() -> MemoryPressureLevel {
        systemPressure
    }
}

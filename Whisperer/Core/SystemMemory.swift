//
//  SystemMemory.swift
//  Whisperer
//
//  Query available system memory for pre-load safety checks
//

import Foundation
import Darwin

enum SystemMemory {

    /// Available memory in GB (free + inactive + purgeable pages).
    /// Fails open (returns .greatestFiniteMagnitude) if the query fails,
    /// so a broken query never blocks model loading.
    static func availableGB() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            Logger.warning("Failed to query system memory (kern_return: \(result))", subsystem: .model)
            return Double.greatestFiniteMagnitude
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let freePages = UInt64(stats.free_count)
        let inactivePages = UInt64(stats.inactive_count)
        let purgeablePages = UInt64(stats.purgeable_count)

        let availableBytes = (freePages + inactivePages + purgeablePages) * pageSize
        return Double(availableBytes) / 1_073_741_824.0
    }
}

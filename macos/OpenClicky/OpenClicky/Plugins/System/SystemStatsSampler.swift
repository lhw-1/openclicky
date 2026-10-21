//
//  SystemStatsSampler.swift
//  OpenClicky
//
//  The live sampler behind the System component: CPU ticks and memory pages from Mach, the boot
//  volume's capacity from the file system, the battery from IOKit's power sources.
//

import Foundation
import IOKit.ps

struct MachSystemStatsSampler: SystemStatsSampling {
    /// The last CPU tick totals (user, system, idle, nice), so the next sample can take a delta.
    private var previousTicks: [UInt32]?

    init() {}

    /// Busy ticks over all ticks between two samples; 0 on the first sample or without a delta.
    static func cpuFraction(previous: [UInt32]?, current: [UInt32]) -> Double {
        guard let previous, previous.count == 4, current.count == 4 else { return 0 }
        let deltas = zip(current, previous).map { Double($0) - Double($1) }
        let total = deltas.reduce(0, +)
        guard total > 0 else { return 0 }
        let busy = deltas[0] + deltas[1] + deltas[3]
        return min(max(busy / total, 0), 1)
    }

    mutating func sample() -> SystemStatsSnapshot {
        let ticks = Self.cpuTicks()
        let cpu = Self.cpuFraction(previous: previousTicks, current: ticks)
        previousTicks = ticks
        let (memoryUsed, memoryTotal) = Self.memory()
        let (diskFree, diskTotal) = Self.disk()
        return SystemStatsSnapshot(cpu: cpu, memoryUsed: memoryUsed, memoryTotal: memoryTotal, diskFree: diskFree, diskTotal: diskTotal, battery: Self.battery())
    }

    // MARK: Mach

    /// User, system, idle and nice ticks summed over every CPU.
    private static func cpuTicks() -> [UInt32] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return [0, 0, 0, 0] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var totals = [UInt32](repeating: 0, count: 4)
        let stride = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(cpuCount) {
            for state in 0..<4 {
                totals[state] &+= UInt32(bitPattern: info[cpu * stride + state])
            }
        }
        return totals
    }

    /// Active + wired + compressed pages against the physical memory.
    private static func memory() -> (used: Int64, total: Int64) {
        var total: Int64 = 0
        var size = MemoryLayout<Int64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        let pageSize = Int64(vm_kernel_page_size)
        let used = (Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * pageSize
        return (min(used, total), total)
    }

    // MARK: Disk

    private static func disk() -> (free: Int64, total: Int64) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let free = min(values?.volumeAvailableCapacityForImportantUsage ?? 0, total)
        return (free, total)
    }

    // MARK: Battery

    private static func battery() -> SystemStatsSnapshot.Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Double,
                  let maximum = description[kIOPSMaxCapacityKey] as? Double, maximum > 0 else { continue }
            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let isPluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return SystemStatsSnapshot.Battery(level: min(max(current / maximum, 0), 1), isCharging: isCharging, isPluggedIn: isPluggedIn)
        }
        return nil
    }
}

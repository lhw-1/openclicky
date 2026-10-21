//
//  SystemStats.swift
//  OpenClicky
//
//  The System component's figures: one snapshot of CPU, memory, disk and battery, how each reads
//  on a tile, when a ring warns, and a store that samples only while a tile row is on screen.
//  The live sampler is in `SystemStatsSampler.swift`.
//

import Combine
import Foundation

/// One reading of the Mac. Bytes are bytes; fractions run 0…1.
struct SystemStatsSnapshot: Equatable {
    struct Battery: Equatable {
        var level: Double
        var isCharging: Bool
        var isPluggedIn: Bool
    }

    var cpu: Double
    var memoryUsed: Int64
    var memoryTotal: Int64
    var diskFree: Int64
    var diskTotal: Int64
    /// Nil on a Mac without an internal battery.
    var battery: Battery?

    static let empty = SystemStatsSnapshot(cpu: 0, memoryUsed: 0, memoryTotal: 0, diskFree: 0, diskTotal: 0, battery: nil)
}

/// Where a snapshot comes from; the live one asks Mach and IOKit, tests hand back fixed values.
protocol SystemStatsSampling {
    mutating func sample() -> SystemStatsSnapshot
}

/// How the figures read on a tile: short inside the ring, long in the caption on hover.
enum SystemStatsFormatter {
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    /// Whole gigabytes (1 GB = 2^30 bytes), rounded.
    static func gigabytes(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_073_741_824).rounded())) GB"
    }

    static func memory(used: Int64, total: Int64) -> String {
        "\(Int((Double(used) / 1_073_741_824).rounded())) / \(gigabytes(total))"
    }

    static func disk(free: Int64) -> String {
        "\(gigabytes(free)) free"
    }

    static func battery(level: Double, isCharging: Bool) -> String {
        isCharging ? "\(percent(level)) ⚡" : percent(level)
    }
}

/// When a ring turns amber: a load above 85 %, a battery at or under 20 %.
enum SystemStatsTone {
    static func isWarning(fraction: Double) -> Bool { fraction > 0.85 }
    static func isWarning(batteryLevel: Double) -> Bool { batteryLevel <= 0.2 }
}

/// One per app: samples every `interval` seconds while at least one tile row watches, and not
/// at all otherwise, so a closed island costs nothing.
@MainActor
final class SystemStatsStore: ObservableObject {
    @Published private(set) var snapshot: SystemStatsSnapshot = .empty

    private var sampler: any SystemStatsSampling
    private let interval: TimeInterval
    private var watchers = 0
    private var timer: Timer?

    init(sampler: any SystemStatsSampling, interval: TimeInterval = 2) {
        self.sampler = sampler
        self.interval = interval
    }

    var isSampling: Bool { timer != nil }

    /// A tile row appeared: the first one samples now and starts the clock.
    func beginWatching() {
        watchers += 1
        guard timer == nil else { return }
        sampleNow()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleNow() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A tile row went away: the last one stops the clock.
    func endWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func sampleNow() {
        let next = sampler.sample()
        if next != snapshot { snapshot = next }
    }
}

//
//  SystemStatsTests.swift
//  OpenClickyTests
//
//  The System component's figures: how they read, when a ring warns, and that the store samples
//  only while a tile row is on screen.
//

import Foundation
import Testing
@testable import OpenClicky

struct SystemStatsTests {
    @Test func figuresReadLikeAGlance() {
        #expect(SystemStatsFormatter.percent(0.234) == "23%")
        #expect(SystemStatsFormatter.percent(1.2) == "100%")
        #expect(SystemStatsFormatter.gigabytes(17_179_869_184) == "16 GB")
        #expect(SystemStatsFormatter.gigabytes(1_099_511_627_776) == "1024 GB")
        #expect(SystemStatsFormatter.memory(used: 7_516_192_768, total: 17_179_869_184) == "7 / 16 GB")
        #expect(SystemStatsFormatter.disk(free: 225_485_783_040) == "210 GB free")
        #expect(SystemStatsFormatter.battery(level: 0.86, isCharging: true) == "86% ⚡")
        #expect(SystemStatsFormatter.battery(level: 0.17, isCharging: false) == "17%")
    }

    @Test func ringsTurnAmberAboveEightyFivePercentAndBatteriesUnderTwenty() {
        #expect(!SystemStatsTone.isWarning(fraction: 0.85))
        #expect(SystemStatsTone.isWarning(fraction: 0.851))
        #expect(SystemStatsTone.isWarning(batteryLevel: 0.2))
        #expect(!SystemStatsTone.isWarning(batteryLevel: 0.21))
    }

    @MainActor @Test func theStoreSamplesWhileAnyViewWatchesAndStopsWithTheLast() {
        struct Counting: SystemStatsSampling {
            var count = 0
            mutating func sample() -> SystemStatsSnapshot {
                count += 1
                return SystemStatsSnapshot(cpu: Double(count) / 10, memoryUsed: 1, memoryTotal: 2, diskFree: 3, diskTotal: 4, battery: nil)
            }
        }
        let store = SystemStatsStore(sampler: Counting(), interval: 60)
        #expect(!store.isSampling)
        store.beginWatching()
        store.beginWatching()
        #expect(store.isSampling)
        #expect(store.snapshot.cpu == 0.1)   // sampled at once, exactly once
        store.endWatching()
        #expect(store.isSampling)
        store.endWatching()
        #expect(!store.isSampling)
    }
}

//
//  NetworkReachability.swift
//  OpenClicky
//
//  Whether the Mac has a network path right now, so the AI clean-up of a take is skipped at once
//  when offline instead of waiting for a request to time out. NWPathMonitor reports on its own
//  queue; the last answer is kept behind a lock. Until the first report it says "online", so a
//  take is never treated as offline by mistake.
//

import Foundation
import Network

final class NetworkReachability: @unchecked Sendable {
    static let shared = NetworkReachability()

    private let pathMonitor = NWPathMonitor()
    private let lock = NSLock()
    private var lastKnownIsOnline = true

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.lastKnownIsOnline = path.status == .satisfied
            self.lock.unlock()
        }
        pathMonitor.start(queue: DispatchQueue(label: "openclicky.network-reachability"))
    }

    var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastKnownIsOnline
    }
}

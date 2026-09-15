import SwiftUI
import MetricKit
import OSLog

@main
struct LampApp: App {
    @StateObject private var store = LampStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        LampMetricSubscriber.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .task { await store.synchronize() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await store.synchronize() }
                }
        }
    }
}

final class LampMetricSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = LampMetricSubscriber()
    private let logger = Logger(subsystem: "com.lamp.planner", category: "metrics")
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        logger.info("metrickit metrics received count=\(payloads.count, privacy: .public)")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let crashCount = payloads.reduce(0) { $0 + ($1.crashDiagnostics?.count ?? 0) }
        logger.error("metrickit diagnostics received count=\(payloads.count, privacy: .public) crashes=\(crashCount, privacy: .public)")
    }
}

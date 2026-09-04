// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LampCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "LampCore", targets: ["LampCore"])],
    targets: [
        .target(
            name: "LampCore",
            path: "Lamp",
            exclude: [
                "AgentAPIClient.swift", "AppIntents.swift", "DesignSystem.swift", "ImageIngestionService.swift", "Info.plist", "LampActivityAttributes.swift", "LampActivityManager.swift", "LampApp.swift", "LampStore.swift",
                "MemoryView.swift", "OnboardingView.swift", "ReplanView.swift", "RoadmapView.swift",
                "RootView.swift", "SpeechService.swift", "TellLampView.swift", "TodayView.swift", "WeekView.swift"
            ],
            sources: ["Models.swift", "PlanningEngine.swift", "DemoData.swift"]
        ),
        .testTarget(name: "LampCoreTests", dependencies: ["LampCore"], path: "Tests/LampCoreTests")
    ]
)

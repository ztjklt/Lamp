import SwiftUI
import UIKit

enum LampDestination: String, CaseIterable, Hashable {
    case today = "今天"
    case week = "日程"
    case tell = "Lamp"
    case roadmap = "路线"
    case profile = "我的"

    var icon: String {
        switch self {
        case .today: "sparkles"
        case .week: "calendar"
        case .tell: "waveform.circle.fill"
        case .roadmap: "point.topleft.down.curvedto.point.bottomright.up"
        case .profile: "person.crop.circle"
        }
    }

    var accessibilityID: String { "tab.\(String(describing: self))" }
}

enum PresentedFlow: Identifiable, Equatable {
    case tellLamp
    case task(ScheduleBlock)
    case partial(ScheduleBlock)
    case missed(ScheduleBlock)
    case privacy
    case replan
    case weeklySchedulePreview

    var id: String {
        switch self {
        case .tellLamp: "tell-lamp"
        case let .task(block): "task-\(block.id)"
        case let .partial(block): "partial-\(block.id)"
        case let .missed(block): "missed-\(block.id)"
        case .privacy: "privacy"
        case .replan: "replan"
        case .weeklySchedulePreview: "weekly-schedule-preview"
        }
    }
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var destination: LampDestination = .today
    @Published var presentedFlow: PresentedFlow?

    func show(_ flow: PresentedFlow) {
        presentedFlow = flow
    }
}

struct RootView: View {
    @EnvironmentObject private var store: LampStore
    @StateObject private var router = AppRouter()

    var body: some View {
        Group {
            if store.hasCompletedOnboarding {
                AppShell()
                    .environmentObject(router)
            } else {
                OnboardingView()
            }
        }
        .animation(.easeInOut(duration: 0.35), value: store.hasCompletedOnboarding)
    }
}

struct AppShell: View {
    @EnvironmentObject private var store: LampStore
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: destinationBinding) {
            TodayView()
                .tag(LampDestination.today)
                .tabItem { Label(LampDestination.today.rawValue, systemImage: LampDestination.today.icon) }
                .accessibilityIdentifier(LampDestination.today.accessibilityID)

            ScheduleView()
                .tag(LampDestination.week)
                .tabItem { Label(LampDestination.week.rawValue, systemImage: LampDestination.week.icon) }
                .accessibilityIdentifier(LampDestination.week.accessibilityID)

            Color.clear
                .tag(LampDestination.tell)
                .tabItem {
                    Label {
                        Text(LampDestination.tell.rawValue)
                    } icon: {
                        Image(uiImage: LampTabIcon.image)
                            .accessibilityIdentifier("global.tellLamp")
                    }
                    .accessibilityLabel("和 Lamp 对话")
                    .accessibilityHint("打开文字、语音和图片日程输入")
                    .accessibilityIdentifier("global.tellLamp")
                }
                .accessibilityIdentifier("global.tellLamp")

            RoadmapView()
                .tag(LampDestination.roadmap)
                .tabItem { Label(LampDestination.roadmap.rawValue, systemImage: LampDestination.roadmap.icon) }
                .accessibilityIdentifier(LampDestination.roadmap.accessibilityID)

            MemoryView(showPrivacy: { router.show(.privacy) })
                .tag(LampDestination.profile)
                .tabItem { Label(LampDestination.profile.rawValue, systemImage: LampDestination.profile.icon) }
                .accessibilityIdentifier(LampDestination.profile.accessibilityID)
        }
        .tint(LampTheme.amber)
        .background(TabBarAccessibilityConfigurator())
        .sheet(item: $router.presentedFlow) { flow in
            presentedView(for: flow)
        }
        .overlay(alignment: .top) {
            if let toast = store.toast {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(LampTheme.sage)
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if store.undoTransaction != nil {
                        Button("撤销") { store.undoLastAction() }
                            .font(.subheadline.weight(.bold))
                            .accessibilityIdentifier("toast.undo")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .lampGlass(.regular, cornerRadius: 22)
                .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast) {
                    do {
                        try await Task.sleep(for: .seconds(6))
                    } catch {
                        return
                    }
                    guard store.toast == toast else { return }
                    withAnimation { store.toast = nil }
                }
            }
        }
        .onAppear { consumeSharedActions() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { consumeSharedActions() }
        }
        .onChange(of: store.pendingReplan?.id) { _, id in
            guard id != nil else { return }
            presentPendingFlow(after: .milliseconds(150))
        }
        .onChange(of: store.pendingWeeklySchedule?.id) { _, id in
            guard id != nil else { return }
            presentPendingFlow(after: .milliseconds(300))
        }
        .onChange(of: router.presentedFlow) { _, flow in
            guard flow == nil else { return }
            presentPendingFlow(after: .milliseconds(250))
        }
    }

    private var destinationBinding: Binding<LampDestination> {
        Binding(
            get: { router.destination },
            set: { newValue in
                if newValue == .tell {
                    router.show(.tellLamp)
                } else {
                    router.destination = newValue
                }
            }
        )
    }

    @ViewBuilder
    private func presentedView(for flow: PresentedFlow) -> some View {
        switch flow {
        case .tellLamp:
            TellLampView()
        case let .task(block):
            TaskDetailView(block: block)
        case let .partial(block):
            PartialCompletionView(block: block)
        case let .missed(block):
            MissedTaskView(block: block)
        case .privacy:
            PrivacyDataView()
        case .replan:
            ReplanView()
        case .weeklySchedulePreview:
            WeeklySchedulePreviewView()
        }
    }

    private func presentPendingFlow(after delay: Duration) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard router.presentedFlow == nil else { return }
            if store.pendingReplan != nil {
                router.show(.replan)
            } else if store.pendingWeeklySchedule != nil {
                router.show(.weeklySchedulePreview)
            }
        }
    }

    private func consumeSharedActions() {
        for action in store.drainSharedActions() {
            switch action.kind {
            case .openToday:
                router.destination = .today
            case .tellLamp:
                router.show(.tellLamp)
            case .completeTask:
                guard let taskID = action.taskID,
                      let id = UUID(uuidString: taskID),
                      let block = store.blocks.first(where: { $0.id == id }),
                      block.state != .completed else { continue }
                store.complete(block)
            case .partialTask:
                guard let taskID = action.taskID,
                      let id = UUID(uuidString: taskID),
                      let block = store.blocks.first(where: { $0.id == id }) else { continue }
                router.destination = .today
                router.show(.partial(block))
            }
        }
    }
}

/// SwiftUI does not consistently forward tab-item identifiers to UITabBarItem on every iOS release.
/// Apply them at the native tab-bar boundary so VoiceOver and UI automation see stable controls.
private struct TabBarAccessibilityConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let root = uiView.window?.rootViewController,
                  let tabBarController = findTabBarController(in: root),
                  let items = tabBarController.tabBar.items,
                  items.count >= LampDestination.allCases.count else { return }

            let identifiers = ["tab.today", "tab.week", "global.tellLamp", "tab.roadmap", "tab.profile"]
            for (item, identifier) in zip(items, identifiers) {
                item.accessibilityIdentifier = identifier
            }
            items[2].accessibilityLabel = "和 Lamp 对话"
            items[2].accessibilityHint = "打开文字、语音和图片日程输入"
        }
    }

    private func findTabBarController(in controller: UIViewController) -> UITabBarController? {
        if let tabBarController = controller as? UITabBarController { return tabBarController }
        for child in controller.children {
            if let result = findTabBarController(in: child) { return result }
        }
        if let presented = controller.presentedViewController {
            return findTabBarController(in: presented)
        }
        return nil
    }
}

private enum LampTabIcon {
    static let image: UIImage = {
        let configuration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let symbol = UIImage(
            systemName: LampDestination.tell.icon,
            withConfiguration: configuration
        ) ?? UIImage()
        return symbol.withTintColor(LampTheme.amberUIColor, renderingMode: .alwaysOriginal)
    }()
}

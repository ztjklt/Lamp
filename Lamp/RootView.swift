import SwiftUI

enum LampDestination: String, CaseIterable, Hashable {
    case today = "今天"
    case week = "本周"
    case tell = "告诉"
    case roadmap = "路线"
    case profile = "我的"

    var icon: String {
        switch self {
        case .today: "sparkles"
        case .week: "calendar"
        case .tell: "waveform"
        case .roadmap: "point.topleft.down.curvedto.point.bottomright.up"
        case .profile: "person.crop.circle"
        }
    }

    var accessibilityID: String { "tab.\(String(describing: self))" }
}

enum PresentedFlow: Identifiable, Equatable {
    case tellLamp
    case task(UUID)
    case partial(UUID)
    case missed(UUID)
    case privacy
    case replan

    var id: String {
        switch self {
        case .tellLamp: "tell-lamp"
        case let .task(id): "task-\(id)"
        case let .partial(id): "partial-\(id)"
        case let .missed(id): "missed-\(id)"
        case .privacy: "privacy"
        case .replan: "replan"
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
            TodayView(showTellLamp: { router.show(.tellLamp) })
                .tag(LampDestination.today)
                .tabItem { Label(LampDestination.today.rawValue, systemImage: LampDestination.today.icon) }
                .accessibilityIdentifier(LampDestination.today.accessibilityID)

            WeekView()
                .tag(LampDestination.week)
                .tabItem { Label(LampDestination.week.rawValue, systemImage: LampDestination.week.icon) }
                .accessibilityIdentifier(LampDestination.week.accessibilityID)

            Color.clear
                .tag(LampDestination.tell)
                .tabItem { Label(LampDestination.tell.rawValue, systemImage: LampDestination.tell.icon) }
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
            if router.presentedFlow == nil {
                router.show(.replan)
            }
        }
        .onChange(of: router.presentedFlow) { _, flow in
            guard flow == nil, store.pendingReplan != nil else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                if router.presentedFlow == nil, store.pendingReplan != nil {
                    router.show(.replan)
                }
            }
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
        case let .task(id):
            if let block = store.blocks.first(where: { $0.id == id }) {
                TaskDetailView(block: block)
            }
        case let .partial(id):
            if let block = store.blocks.first(where: { $0.id == id }) {
                PartialCompletionView(block: block)
            }
        case let .missed(id):
            if let block = store.blocks.first(where: { $0.id == id }) {
                MissedTaskView(block: block)
            }
        case .privacy:
            PrivacyDataView()
        case .replan:
            ReplanView()
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
                      store.blocks.contains(where: { $0.id == id }) else { continue }
                router.destination = .today
                router.show(.partial(id))
            }
        }
    }
}

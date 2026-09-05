import SwiftUI

enum LampDestination: String, CaseIterable, Hashable {
    case today = "今天"
    case week = "本周"
    case roadmap = "路线"
    case profile = "我的"

    var icon: String {
        switch self {
        case .today: "sparkles"
        case .week: "calendar"
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

    var id: String {
        switch self {
        case .tellLamp: "tell-lamp"
        case let .task(block): "task-\(block.id)"
        case let .partial(block): "partial-\(block.id)"
        case let .missed(block): "missed-\(block.id)"
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
            TodayView()
                .tag(LampDestination.today)
                .tabItem { Label(LampDestination.today.rawValue, systemImage: LampDestination.today.icon) }
                .accessibilityIdentifier(LampDestination.today.accessibilityID)

            WeekView()
                .tag(LampDestination.week)
                .tabItem { Label(LampDestination.week.rawValue, systemImage: LampDestination.week.icon) }
                .accessibilityIdentifier(LampDestination.week.accessibilityID)

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
        .overlay(alignment: .bottom) {
            GlobalTellLampButton {
                router.show(.tellLamp)
            }
            .padding(.bottom, 58)
        }
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

    private var destinationBinding: Binding<LampDestination> { $router.destination }

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

private struct GlobalTellLampButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glowing = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .bold))
                    .symbolEffect(.variableColor.iterative, isActive: !reduceMotion && glowing)
                Text("和 Lamp 对话")
                    .font(.headline.weight(.bold))
            }
            .foregroundStyle(.white)
            .frame(minWidth: 174, minHeight: 58)
            .padding(.horizontal, 18)
            .background(
                LinearGradient(
                    colors: [
                        LampTheme.amberSoft.opacity(0.88),
                        LampTheme.amber.opacity(0.90),
                        Color(red: 0.91, green: 0.36, blue: 0.08).opacity(0.92)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .overlay(Capsule().stroke(.white.opacity(0.48), lineWidth: 1))
            .lampGlass(.prominent, cornerRadius: 30)
            .shadow(color: LampTheme.amber.opacity(glowing ? 0.46 : 0.25), radius: glowing ? 24 : 14, y: 8)
            .scaleEffect(!reduceMotion && glowing ? 1.018 : 1)
        }
        .buttonStyle(GlobalLampPressStyle())
        .accessibilityIdentifier("global.tellLamp")
        .accessibilityHint("打开文字、语音和图片日程输入")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                glowing = true
            }
        }
    }
}

private struct GlobalLampPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

import SwiftUI

enum LampDestination: String, CaseIterable {
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
}

struct RootView: View {
    @EnvironmentObject private var store: LampStore

    var body: some View {
        Group {
            if store.hasCompletedOnboarding {
                AppShell()
            } else {
                OnboardingView()
            }
        }
        .animation(.easeInOut(duration: 0.35), value: store.hasCompletedOnboarding)
    }
}

struct AppShell: View {
    @EnvironmentObject private var store: LampStore
    @State private var destination: LampDestination = .today
    @State private var showingTellLamp = false

    var body: some View {
        ZStack(alignment: .bottom) {
            LampTheme.background.ignoresSafeArea()

            Group {
                switch destination {
                case .today: TodayView(showTellLamp: { showingTellLamp = true })
                case .week: WeekView()
                case .roadmap: RoadmapView()
                case .profile: MemoryView()
                }
            }
            .padding(.bottom, 84)

            bottomBar
        }
        .sheet(isPresented: $showingTellLamp) { TellLampView() }
        .sheet(item: $store.pendingReplan) { _ in ReplanView() }
        .overlay(alignment: .top) {
            if let toast = store.toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 12)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2.6))
                        withAnimation { store.toast = nil }
                    }
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 2) {
            ForEach(LampDestination.allCases, id: \.self) { item in
                Button {
                    withAnimation(.snappy) { destination = item }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 17, weight: destination == item ? .semibold : .regular))
                        Text(item.rawValue).font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(destination == item ? LampTheme.ink : .secondary)
                    .frame(maxWidth: .infinity)
                }
            }

            Button { showingTellLamp = true } label: {
                ZStack {
                    Circle().fill(LampTheme.ink).frame(width: 52, height: 52)
                    Image(systemName: "waveform").font(.title3.weight(.medium)).foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
            }
            .accessibilityLabel("告诉 Lamp")
        }
        .padding(.leading, 10).padding(.trailing, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.75)))
        .padding(.horizontal, 14).padding(.bottom, 6)
    }
}


import SwiftUI

struct ReplanView: View {
    @EnvironmentObject private var store: LampStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                LampTheme.background.ignoresSafeArea()
                if let proposal = store.pendingReplan {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            HStack(spacing: 15) {
                                LampLight(size: 52)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(proposal.title).font(.title2.bold())
                                    Text(proposal.summary).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            LampCard {
                                VStack(alignment: .leading, spacing: 14) {
                                    SectionLabel(title: "将会改变")
                                    ForEach(proposal.changes, id: \.self) { change in
                                        Label(change, systemImage: "arrow.right.circle.fill")
                                            .font(.subheadline).foregroundStyle(LampTheme.ink)
                                    }
                                }
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                SectionLabel(title: "为什么")
                                Text(proposal.reason).font(.body.weight(.medium))
                                Text("这是临时状态，不会自动变成对你的长期判断。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 12) {
                                Button("保留原计划") { store.pendingReplan = nil; dismiss() }
                                    .buttonStyle(.bordered).tint(LampTheme.ink).frame(maxWidth: .infinity)
                                Button("应用调整") { store.applyPendingReplan(); dismiss() }
                                    .buttonStyle(.borderedProminent).tint(LampTheme.ink).frame(maxWidth: .infinity)
                            }
                            .controlSize(.large)
                        }
                        .padding(22)
                    }
                }
            }
            .navigationTitle("调整预览").navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }
}


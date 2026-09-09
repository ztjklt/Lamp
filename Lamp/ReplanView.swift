import SwiftUI

struct ReplanView: View {
    @EnvironmentObject private var store: LampStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                LampBackground()
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
                                    SectionLabel(title: changeSectionTitle(for: proposal.mode))
                                    ForEach(proposal.changes, id: \.self) { change in
                                        Label(change, systemImage: "arrow.right.circle.fill")
                                            .font(.subheadline).foregroundStyle(LampTheme.ink)
                                    }
                                }
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                SectionLabel(title: "为什么")
                                Text(proposal.reason).font(.body.weight(.medium))
                                if proposal.mode == .dayPlan {
                                    Text("这是候选方案。只有点击确认后，专注时段才会加入时间线。")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if proposal.mode == .incompleteTask {
                                    Text("未完成记录已经保存；只有点击确认后，才会调整后续安排。")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if proposal.mode == .languageReplan {
                                    Text("模型只负责理解意图和给出结构化目标；时间计算与冲突检查由 Planner 完成。只有确认后才会修改时间线。")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("这是临时状态，不会自动变成对你的长期判断。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 12) {
                                Button(keepButtonTitle(for: proposal.mode)) { store.dismissPendingReplan(); dismiss() }
                                    .buttonStyle(.lamp).frame(maxWidth: .infinity)
                                    .accessibilityIdentifier("replan.keep")
                                Button(applyButtonTitle(for: proposal.mode)) { store.applyPendingReplan(); dismiss() }
                                    .buttonStyle(.lampProminent).frame(maxWidth: .infinity)
                                    .accessibilityIdentifier("replan.apply")
                            }
                        }
                        .padding(22)
                    }
                }
            }
            .navigationTitle(navigationTitle(for: store.pendingReplan?.mode))
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }

    private func changeSectionTitle(for mode: ReplanProposalMode) -> String {
        switch mode {
        case .dayPlan: "准备加入"
        case .incompleteTask: "建议调整"
        case .languageReplan: "模型理解 + Planner 结果"
        case .adjustment: "将会改变"
        }
    }

    private func keepButtonTitle(for mode: ReplanProposalMode) -> String {
        switch mode {
        case .dayPlan: "暂不安排"
        case .incompleteTask, .languageReplan: "暂不调整"
        case .adjustment: "保留原计划"
        }
    }

    private func applyButtonTitle(for mode: ReplanProposalMode) -> String {
        switch mode {
        case .dayPlan: "加入今日计划"
        case .incompleteTask: "应用重排"
        case .languageReplan: "应用轻量调整"
        case .adjustment: "应用调整"
        }
    }

    private func navigationTitle(for mode: ReplanProposalMode?) -> String {
        switch mode {
        case .dayPlan: "计划预览"
        case .incompleteTask: "重排预览"
        case .languageReplan: "语言调整预览"
        case .adjustment, nil: "调整预览"
        }
    }
}

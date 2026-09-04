import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: LampStore
    var showTellLamp: () -> Void

    private var dayTitle: String {
        Date.now.formatted(.dateTime.month(.wide).day().weekday(.wide).locale(Locale(identifier: "zh_CN")))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                header
                nowSection
                HStack {
                    SectionLabel(title: "Today", trailing: "专注 \(store.focusMinutesToday / 60) 小时 \(store.focusMinutesToday % 60) 分")
                }
                timeline
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("早上好").font(.largeTitle.bold()).foregroundStyle(LampTheme.ink)
                Text(dayTitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: showTellLamp) { LampLight(size: 42) }
        }
    }

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Now")
            if let block = store.currentOrNextBlock {
                LampCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(block.title).font(.title2.bold()).foregroundStyle(LampTheme.ink)
                                Text("\(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened)) · \(block.durationMinutes) 分钟")
                                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                        }
                        ProgressView(value: progress(for: block))
                            .tint(LampTheme.amber)
                        HStack(spacing: 10) {
                            taskButton("完成", "checkmark", .completed, block)
                            taskButton("部分", "circle.lefthalf.filled", .partial, block)
                            taskButton("未做", "xmark", .missed, block)
                        }
                        Label(block.reason, systemImage: "lightbulb.min")
                            .font(.caption).foregroundStyle(LampTheme.muted)
                        Button {
                            Task {
                                do {
                                    try await LampActivityManager.start(for: block)
                                    store.toast = "已在锁屏与灵动岛跟随当前任务"
                                } catch {
                                    store.toast = "暂时无法启动锁屏活动"
                                }
                            }
                        } label: {
                            Label("在锁屏上跟随", systemImage: "iphone.gen3")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(LampTheme.ink)
                    }
                }
            } else {
                LampCard {
                    HStack(spacing: 14) {
                        Image(systemName: "cup.and.saucer.fill").foregroundStyle(LampTheme.sage)
                        VStack(alignment: .leading) {
                            Text("现在可以休息").font(.headline)
                            Text("Lamp 没有必要把每个空档都填满。 ").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.todayBlocks.enumerated()), id: \.element.id) { index, block in
                HStack(alignment: .top, spacing: 13) {
                    Text(block.start.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading).padding(.top, 15)
                    VStack(spacing: 0) {
                        Circle().fill(block.kind.color).frame(width: 9, height: 9).padding(.top, 19)
                        if index < store.todayBlocks.count - 1 { Rectangle().fill(.black.opacity(0.08)).frame(width: 1).frame(maxHeight: .infinity) }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(block.title).font(.body.weight(.semibold))
                                .strikethrough(block.state == .completed)
                            Spacer()
                            if block.state != .planned {
                                Image(systemName: stateIcon(block.state)).foregroundStyle(block.state == .completed ? LampTheme.sage : LampTheme.amber)
                            }
                        }
                        Text("\(block.durationMinutes) 分钟 · \(block.provenance)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14).background(.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 18))
                    .opacity(block.state == .missed ? 0.5 : 1)
                }
                .frame(minHeight: 78)
            }
        }
    }

    private func progress(for block: ScheduleBlock) -> Double {
        guard Date.now >= block.start else { return 0 }
        return min(1, max(0, Date.now.timeIntervalSince(block.start) / block.end.timeIntervalSince(block.start)))
    }

    private func taskButton(_ title: String, _ icon: String, _ state: CompletionState, _ block: ScheduleBlock) -> some View {
        Button { store.mark(block, as: state) } label: {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
        }
        .buttonStyle(.plain).background(LampTheme.background, in: Capsule())
    }

    private func stateIcon(_ state: CompletionState) -> String {
        switch state {
        case .completed: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .missed: "xmark.circle"
        case .active: "play.circle.fill"
        case .planned: "circle"
        }
    }
}

import SwiftUI

struct WeekView: View {
    @EnvironmentObject private var store: LampStore
    @EnvironmentObject private var router: AppRouter
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    private let calendar = Calendar.current

    private var days: [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var selectedBlocks: [ScheduleBlock] { store.blocks(on: selectedDay) }
    private var dailyMinutes: [Int] { days.map(store.focusMinutes(on:)) }
    private var workload: Double { min(1, Double(store.weeklyFocusMinutes) / (35 * 60)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LampTheme.Spacing.section) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本周").font(.largeTitle.bold())
                        Text("让重要的事装得进现实。")
                            .foregroundStyle(.secondary)
                    }
                    dayStrip
                    workloadCard
                    SectionLabel(title: selectedDay.formatted(.dateTime.weekday(.wide).month().day().locale(Locale(identifier: "zh_CN"))))
                    selectedDayContent
                    insight
                }
                .padding(.horizontal, LampTheme.Spacing.page)
                .padding(.top, 20)
                .padding(.bottom, 44)
            }
            .scrollIndicators(.hidden)
            .navigationBarHidden(true)
            .lampPage()
        }
    }

    private var dayStrip: some View {
        HStack(spacing: 7) {
            ForEach(days, id: \.self) { day in
                let selected = calendar.isDate(day, inSameDayAs: selectedDay)
                Button {
                    withAnimation(.snappy) { selectedDay = day }
                } label: {
                    VStack(spacing: 7) {
                        Text(day.formatted(.dateTime.weekday(.narrow).locale(Locale(identifier: "zh_CN"))))
                            .font(.caption)
                        Text(day.formatted(.dateTime.day())).font(.body.weight(.semibold))
                        Circle()
                            .fill(calendar.isDateInToday(day) ? LampTheme.amber : .clear)
                            .frame(width: 5, height: 5)
                    }
                    .foregroundStyle(selected ? LampTheme.onPrimaryAction : LampTheme.ink)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .padding(.vertical, 6)
                    .background(selected ? LampTheme.primaryAction : LampTheme.secondaryBackground.opacity(0.76), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day().locale(Locale(identifier: "zh_CN"))))
                .accessibilityValue(selected ? "已选择" : "")
                .accessibilityIdentifier("week.day.\(calendar.component(.weekday, from: day))")
            }
        }
    }

    private var workloadCard: some View {
        LampCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("本周负荷").font(.headline)
                        Text(workloadDescription).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(workload, format: .percent.precision(.fractionLength(0)))
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(workload > 0.85 ? LampTheme.danger : LampTheme.sage)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    let maximum = max(60, dailyMinutes.max() ?? 60)
                    ForEach(Array(dailyMinutes.enumerated()), id: \.offset) { index, minutes in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(calendar.isDateInToday(days[index]) ? LampTheme.amber : LampTheme.sage.opacity(0.58))
                            .frame(height: max(8, 72 * CGFloat(minutes) / CGFloat(maximum)))
                            .accessibilityLabel("\(days[index].formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "zh_CN"))))专注 \(minutes) 分钟")
                    }
                }
                .frame(height: 74, alignment: .bottom)
                Text("共 \(store.weeklyFocusMinutes / 60) 小时 \(store.weeklyFocusMinutes % 60) 分钟专注安排")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var selectedDayContent: some View {
        if selectedBlocks.isEmpty {
            LampCard {
                HStack(spacing: 14) {
                    Image(systemName: "wind").font(.title2).foregroundStyle(LampTheme.sage)
                    VStack(alignment: .leading) {
                        Text("这一天还很空").font(.headline)
                        Text("保留空白也是计划的一部分。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            ForEach(selectedBlocks) { block in
                Button {
                    router.show(.task(block))
                } label: {
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 2).fill(block.kind.color).frame(width: 4, height: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(block.title).font(.body.weight(.semibold)).foregroundStyle(LampTheme.ink)
                            Text("\(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(block.kind == .fixed ? "固定" : "灵活")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(block.kind.color)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(block.kind.color.opacity(0.12), in: Capsule())
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(LampTheme.secondaryBackground.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("week.block.\(block.id.uuidString)")
            }
        }
    }

    private var insight: some View {
        HStack(alignment: .top, spacing: 13) {
            LampLight(size: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text("Lamp 的观察").font(.subheadline.weight(.semibold))
                Text(insightText)
                    .font(.subheadline).foregroundStyle(LampTheme.muted).lineSpacing(3)
            }
        }
        .padding(16)
        .background(LampTheme.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var workloadDescription: String {
        switch workload {
        case ..<0.35: "节奏较轻，保留了充足余地"
        case ..<0.75: "节奏健康，还留有余地"
        case ..<0.9: "安排偏满，注意恢复时间"
        default: "负荷较高，建议重新评估"
        }
    }

    private var insightText: String {
        guard let nearest = store.planItems
            .filter({ $0.deadline != nil && $0.remainingMinutes > 0 })
            .sorted(by: { $0.deadline! < $1.deadline! })
            .first,
              let deadline = nearest.deadline else {
            return "本周没有迫近的截止日期。Lamp 会继续保留恢复时间和可调整空间。"
        }
        let daysLeft = max(0, calendar.dateComponents([.day], from: .now, to: deadline).day ?? 0)
        return "“\(nearest.title)”还有 \(daysLeft) 天，剩余约 \(nearest.remainingMinutes) 分钟。当前安排会优先保护它的合适时段。"
    }
}

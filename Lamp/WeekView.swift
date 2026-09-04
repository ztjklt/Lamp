import SwiftUI

struct WeekView: View {
    @EnvironmentObject private var store: LampStore
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    private let calendar = Calendar.current

    private var days: [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var selectedBlocks: [ScheduleBlock] {
        store.blocks.filter { calendar.isDate($0.start, inSameDayAs: selectedDay) }.sorted { $0.start < $1.start }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本周").font(.largeTitle.bold())
                    Text("让重要的事装得进现实。").foregroundStyle(.secondary)
                }
                dayStrip
                workloadCard
                SectionLabel(title: selectedDay.formatted(.dateTime.weekday(.wide).month().day().locale(Locale(identifier: "zh_CN"))))
                if selectedBlocks.isEmpty {
                    LampCard {
                        HStack {
                            Image(systemName: "wind").font(.title2).foregroundStyle(LampTheme.sage)
                            VStack(alignment: .leading) {
                                Text("这一天还很空").font(.headline)
                                Text("保留空白也是计划的一部分。 ").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    ForEach(selectedBlocks) { block in
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 2).fill(block.kind.color).frame(width: 4, height: 48)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(block.title).font(.body.weight(.semibold))
                                Text("\(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(block.kind == .fixed ? "固定" : "灵活").font(.caption2.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 5).background(block.kind.color.opacity(0.12), in: Capsule())
                        }
                        .padding(14).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                insight
            }
            .padding(.horizontal, 20).padding(.top, 20)
        }
        .scrollIndicators(.hidden)
    }

    private var dayStrip: some View {
        HStack(spacing: 7) {
            ForEach(days, id: \.self) { day in
                let selected = calendar.isDate(day, inSameDayAs: selectedDay)
                Button { withAnimation(.snappy) { selectedDay = day } } label: {
                    VStack(spacing: 8) {
                        Text(day.formatted(.dateTime.weekday(.narrow).locale(Locale(identifier: "zh_CN")))).font(.caption)
                        Text(day.formatted(.dateTime.day())).font(.body.weight(.semibold))
                        Circle().fill(calendar.isDateInToday(day) ? LampTheme.amber : .clear).frame(width: 5, height: 5)
                    }
                    .foregroundStyle(selected ? .white : LampTheme.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(selected ? LampTheme.ink : .white.opacity(0.62), in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain)
            }
        }
    }

    private var workloadCard: some View {
        LampCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("本周负荷").font(.headline)
                        Text("节奏健康，还留有余地").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("72%").font(.title2.bold()).foregroundStyle(LampTheme.sage)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, _ in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(index == 3 ? LampTheme.amber : LampTheme.sage.opacity(0.55))
                            .frame(height: [42, 58, 72, 64, 48, 30, 22][index])
                    }
                }
                .frame(height: 74, alignment: .bottom)
            }
        }
    }

    private var insight: some View {
        HStack(alignment: .top, spacing: 13) {
            LampLight(size: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text("Lamp 的观察").font(.subheadline.weight(.semibold))
                Text("微积分考试进入最后 8 天。本周已优先保留 4 个下午时段，不需要挤占周末全部休息。")
                    .font(.subheadline).foregroundStyle(LampTheme.muted).lineSpacing(3)
            }
        }
        .padding(16).background(LampTheme.amberSoft.opacity(0.3), in: RoundedRectangle(cornerRadius: 20))
    }
}


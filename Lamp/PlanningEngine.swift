import Foundation

struct PlanningContext: Sendable {
    var horizonStart: Date
    var horizonEnd: Date
    var workingHours: ClosedRange<Int> = 8...21
    var fatigueMultiplier: Double = 1
    var preferredFocusPeriod: DayPeriod = .afternoon
    var protectedRanges: [DateInterval] = []
}

struct PlacementExplanation: Equatable, Sendable {
    var deadline: Double
    var importance: Double
    var energyFit: Double
    var stability: Double

    var text: String {
        let factors = [
            (deadline, "临近截止日期"),
            (importance, "目标优先级较高"),
            (energyFit, "符合你的高效时段"),
            (stability, "尽量保持原计划稳定")
        ]
        return factors.max(by: { $0.0 < $1.0 })?.1 ?? "当前最合适的空档"
    }
}

/// Deterministic hybrid planner: feasibility filtering first, explainable scoring second.
struct PlanningEngine: Sendable {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func makeSchedule(
        items: [PlanItem], fixed: [ScheduleBlock], previous: [ScheduleBlock] = [],
        context: PlanningContext
    ) -> [ScheduleBlock] {
        var result = fixed
        let completedIDs = Set(items.filter { $0.progress >= 1 }.map(\.id))
        let eligible = items.filter {
            !$0.isPaused && $0.remainingMinutes > 0 && $0.kind != .goal && $0.kind != .project &&
            $0.dependencyIDs.allSatisfy(completedIDs.contains)
        }
        .sorted { score($0, at: context.horizonStart, context: context) > score($1, at: context.horizonStart, context: context) }

        let dailyBudget = Int(360 * max(0.25, min(context.fatigueMultiplier, 1)))
        var usedByDay: [Date: Int] = [:]

        for item in eligible {
            var remaining = item.remainingMinutes
            let prior = previous.filter { $0.planItemID == item.id && $0.state == .planned }

            while remaining >= 20 {
                let session = min(item.isSplittable ? 90 : remaining, remaining)
                guard let start = bestSlot(
                    for: item, minutes: session, occupied: result,
                    prior: prior, usedByDay: usedByDay, dailyBudget: dailyBudget, context: context
                ) else { break }
                let end = start.addingTimeInterval(TimeInterval(session * 60))
                let explanation = explanation(for: item, at: start, prior: prior, context: context)
                result.append(ScheduleBlock(
                    planItemID: item.id, title: item.title, start: start, end: end, kind: .focus,
                    reason: explanation.text
                ))
                let day = calendar.startOfDay(for: start)
                usedByDay[day, default: 0] += session
                remaining -= session
                if !item.isSplittable { break }
            }
        }

        return result.sorted { $0.start < $1.start }
    }

    func isFeasible(_ blocks: [ScheduleBlock], protected: [DateInterval] = []) -> Bool {
        let sorted = blocks.sorted { $0.start < $1.start }
        for index in sorted.indices.dropFirst() where sorted[index].start < sorted[index - 1].end {
            return false
        }
        return !sorted.contains { block in
            protected.contains { $0.intersects(DateInterval(start: block.start, end: block.end)) }
        }
    }

    func score(_ item: PlanItem, at date: Date, context: PlanningContext) -> Double {
        let days = item.deadline.map { max(0.25, $0.timeIntervalSince(date) / 86_400) } ?? 30
        let urgency = 120 / days
        return urgency + Double(item.importance * 15) + Double(item.remainingMinutes) / 60
    }

    func explanation(
        for item: PlanItem, at date: Date, prior: [ScheduleBlock], context: PlanningContext
    ) -> PlacementExplanation {
        let days = item.deadline.map { max(0.25, $0.timeIntervalSince(date) / 86_400) } ?? 30
        let period = dayPeriod(for: date)
        return PlacementExplanation(
            deadline: min(100, 60 / days),
            importance: Double(item.importance * 12),
            energyFit: period == (item.preferredPeriod ?? context.preferredFocusPeriod) ? 65 : 10,
            stability: prior.contains(where: { abs($0.start.timeIntervalSince(date)) < 900 }) ? 70 : 5
        )
    }

    private func bestSlot(
        for item: PlanItem, minutes: Int, occupied: [ScheduleBlock], prior: [ScheduleBlock],
        usedByDay: [Date: Int], dailyBudget: Int, context: PlanningContext
    ) -> Date? {
        var candidates: [Date] = []
        let workingDayStart = calendar.date(on: context.horizonStart, hour: context.workingHours.lowerBound)
        var cursor = max(context.horizonStart, workingDayStart)
        let minute = calendar.component(.minute, from: cursor)
        if minute % 30 != 0 || calendar.component(.second, from: cursor) != 0 {
            cursor = calendar.date(byAdding: .minute, value: 30 - minute % 30, to: cursor) ?? cursor
            cursor = calendar.date(bySetting: .second, value: 0, of: cursor) ?? cursor
        }
        while cursor.addingTimeInterval(TimeInterval(minutes * 60)) <= context.horizonEnd {
            let hour = calendar.component(.hour, from: cursor)
            let day = calendar.startOfDay(for: cursor)
            if context.workingHours.contains(hour), usedByDay[day, default: 0] + minutes <= dailyBudget {
                let interval = DateInterval(start: cursor, duration: TimeInterval(minutes * 60))
                let collision = occupied.contains { interval.intersects(DateInterval(start: $0.start, end: $0.end)) }
                let protected = context.protectedRanges.contains { interval.intersects($0) }
                if !collision && !protected { candidates.append(cursor) }
            }
            cursor = cursor.addingTimeInterval(30 * 60)
        }

        return candidates.max {
            placementScore(item, at: $0, prior: prior, context: context) <
            placementScore(item, at: $1, prior: prior, context: context)
        }
    }

    private func placementScore(_ item: PlanItem, at date: Date, prior: [ScheduleBlock], context: PlanningContext) -> Double {
        let explanation = explanation(for: item, at: date, prior: prior, context: context)
        let churnPenalty = prior.isEmpty ? 0 : min(30, prior.map { abs($0.start.timeIntervalSince(date)) / 3600 }.min() ?? 0)
        return explanation.deadline + explanation.importance + explanation.energyFit + explanation.stability - churnPenalty
    }

    private func dayPeriod(for date: Date) -> DayPeriod {
        switch calendar.component(.hour, from: date) {
        case ..<12: .morning
        case 12..<18: .afternoon
        default: .evening
        }
    }
}

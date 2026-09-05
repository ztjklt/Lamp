import Foundation
import CryptoKit
import SwiftUI

enum PlanKind: String, Codable, CaseIterable, Sendable {
    case goal, project, milestone, task, step, event, rest
}

enum BlockKind: String, Codable, Sendable {
    case fixed, focus, breakTime, free

    var color: Color {
        switch self {
        case .fixed: .blue
        case .focus: .orange
        case .breakTime: .green
        case .free: .secondary
        }
    }
}

enum CompletionState: String, Codable, Sendable {
    case planned, active, completed, partial, missed
}

enum MemoryStatus: String, Codable, Sendable {
    case inferred, proposed, confirmed
}

struct PlanItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var parentID: UUID?
    var kind: PlanKind
    var title: String
    var detail: String
    var importance: Int
    var deadline: Date?
    var estimatedMinutes: Int
    var remainingMinutes: Int
    var progress: Double
    var isPaused: Bool
    var isSplittable: Bool
    var preferredPeriod: DayPeriod?
    var dependencyIDs: [UUID]

    init(
        id: UUID = UUID(), parentID: UUID? = nil, kind: PlanKind, title: String,
        detail: String = "", importance: Int = 3, deadline: Date? = nil,
        estimatedMinutes: Int = 60, remainingMinutes: Int? = nil, progress: Double = 0,
        isPaused: Bool = false, isSplittable: Bool = true,
        preferredPeriod: DayPeriod? = nil, dependencyIDs: [UUID] = []
    ) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.importance = importance
        self.deadline = deadline
        self.estimatedMinutes = estimatedMinutes
        self.remainingMinutes = remainingMinutes ?? estimatedMinutes
        self.progress = progress
        self.isPaused = isPaused
        self.isSplittable = isSplittable
        self.preferredPeriod = preferredPeriod
        self.dependencyIDs = dependencyIDs
    }
}

enum DayPeriod: String, Codable, CaseIterable, Sendable {
    case morning, afternoon, evening
}

struct ScheduleBlock: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var planItemID: UUID?
    var title: String
    var start: Date
    var end: Date
    var kind: BlockKind
    var state: CompletionState
    var reason: String
    var provenance: String
    var recurringRuleID: UUID?
    var occurrenceDate: Date?

    init(
        id: UUID = UUID(), planItemID: UUID? = nil, title: String, start: Date,
        end: Date, kind: BlockKind, state: CompletionState = .planned,
        reason: String = "", provenance: String = "Lamp",
        recurringRuleID: UUID? = nil, occurrenceDate: Date? = nil
    ) {
        self.id = id
        self.planItemID = planItemID
        self.title = title
        self.start = start
        self.end = end
        self.kind = kind
        self.state = state
        self.reason = reason
        self.provenance = provenance
        self.recurringRuleID = recurringRuleID
        self.occurrenceDate = occurrenceDate
    }

    var durationMinutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
}

struct RecurringScheduleRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var detail: String
    var startsOn: Date
    var endsOn: Date?
    /// Calendar weekday values: Sunday = 1 ... Saturday = 7.
    var weekdays: [Int]
    var startMinute: Int
    var durationMinutes: Int
    var timezone: String
    var kind: BlockKind = .fixed
    var reason: String = "由图片识别的重复日程"
    var provenance: String = "DeepSeek 图片识别 · 用户确认"
}

struct ScheduleOccurrenceOverride: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var recurringRuleID: UUID
    var occurrenceDate: Date
    var state: CompletionState
    var reason: String = ""
    var title: String?
    var start: Date?
    var end: Date?
    var isCancelled: Bool = false
}

enum RecurringScheduleEngine {
    static func occurrence(
        for rule: RecurringScheduleRule,
        on date: Date,
        override: ScheduleOccurrenceOverride? = nil,
        calendar sourceCalendar: Calendar = .current
    ) -> ScheduleBlock? {
        var calendar = sourceCalendar
        calendar.timeZone = TimeZone(identifier: rule.timezone) ?? sourceCalendar.timeZone
        let day = calendar.startOfDay(for: date)
        let firstDay = calendar.startOfDay(for: rule.startsOn)
        guard day >= firstDay else { return nil }
        if let endsOn = rule.endsOn, day > calendar.startOfDay(for: endsOn) { return nil }
        guard rule.weekdays.contains(calendar.component(.weekday, from: day)) else { return nil }
        if override?.isCancelled == true { return nil }

        let start = override?.start
            ?? calendar.date(byAdding: .minute, value: rule.startMinute, to: day)
            ?? day
        let end = override?.end
            ?? calendar.date(byAdding: .minute, value: rule.durationMinutes, to: start)
            ?? start
        return ScheduleBlock(
            id: occurrenceID(ruleID: rule.id, day: day, calendar: calendar),
            title: override?.title ?? rule.title,
            start: start,
            end: end,
            kind: rule.kind,
            state: override?.state ?? .planned,
            reason: override?.reason.isEmpty == false ? override!.reason : rule.reason,
            provenance: rule.provenance,
            recurringRuleID: rule.id,
            occurrenceDate: day
        )
    }

    static func occurrenceID(ruleID: UUID, day: Date, calendar: Calendar = .current) -> UUID {
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        let key = "\(ruleID.uuidString)|\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

enum ImageScheduleRecurrenceKind: String, Codable, CaseIterable, Sendable {
    case none
    case weekly
}

struct ImageScheduleRecurrence: Codable, Hashable, Sendable {
    var kind: ImageScheduleRecurrenceKind
    var weekdays: [Int]
    var startsOn: Date?
    var endsOn: Date?

    static let none = ImageScheduleRecurrence(kind: .none, weekdays: [], startsOn: nil, endsOn: nil)
}

struct ImageScheduleCandidate: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var detail: String
    var startAt: Date?
    var endAt: Date?
    var timezone: String
    var confidence: Double
    var sourceEvidence: String
    var needsReview: Bool
    var recurrence: ImageScheduleRecurrence

    init(
        id: UUID = UUID(), title: String, detail: String = "", startAt: Date? = nil,
        endAt: Date? = nil, timezone: String = TimeZone.current.identifier,
        confidence: Double, sourceEvidence: String = "", needsReview: Bool = false,
        recurrence: ImageScheduleRecurrence = .none
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.startAt = startAt
        self.endAt = endAt
        self.timezone = timezone
        self.confidence = confidence
        self.sourceEvidence = sourceEvidence
        self.needsReview = needsReview
        self.recurrence = recurrence
    }
}

struct ImageScheduleAnalysisResponse: Codable, Sendable {
    var analysisID: UUID
    var summary: String
    var candidates: [ImageScheduleCandidate]
    var warnings: [String]
}

enum ScheduleCandidateValidator {
    static func issue(
        for candidate: ImageScheduleCandidate,
        blocks: [ScheduleBlock],
        recurringSchedules: [RecurringScheduleRule],
        occurrenceOverrides: [ScheduleOccurrenceOverride] = [],
        calendar sourceCalendar: Calendar = .current
    ) -> String? {
        guard !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let start = candidate.startAt,
              let end = candidate.endAt,
              end > start else {
            return "日期或时间不完整"
        }

        var calendar = sourceCalendar
        calendar.timeZone = TimeZone(identifier: candidate.timezone) ?? sourceCalendar.timeZone
        if candidate.recurrence.kind == .weekly {
            let candidateSeriesStart = calendar.startOfDay(for: candidate.recurrence.startsOn ?? start)
            let candidateSeriesEnd = candidate.recurrence.endsOn.map(calendar.startOfDay(for:))
            if let candidateSeriesEnd, candidateSeriesEnd < candidateSeriesStart {
                return "重复日程的结束日期早于开始日期"
            }
            let weekdays = candidate.recurrence.weekdays.isEmpty
                ? [calendar.component(.weekday, from: start)]
                : candidate.recurrence.weekdays
            let startMinute = calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start)
            let durationMinutes = max(1, Int(end.timeIntervalSince(start) / 60))
            let endMinute = startMinute + durationMinutes

            for rule in recurringSchedules where !Set(rule.weekdays).isDisjoint(with: weekdays) {
                let ruleStart = calendar.startOfDay(for: rule.startsOn)
                let ruleEnd = rule.endsOn.map(calendar.startOfDay(for:))
                let datesOverlap = (candidateSeriesEnd == nil || candidateSeriesEnd! >= ruleStart)
                    && (ruleEnd == nil || ruleEnd! >= candidateSeriesStart)
                let ruleEndMinute = rule.startMinute + rule.durationMinutes
                if datesOverlap && startMinute < ruleEndMinute && endMinute > rule.startMinute {
                    if rule.title.localizedCaseInsensitiveCompare(candidate.title) == .orderedSame,
                       startMinute == rule.startMinute,
                       durationMinutes == rule.durationMinutes {
                        return "已存在相同的重复日程“\(rule.title)”"
                    }
                    return "与重复日程“\(rule.title)”冲突"
                }
            }

            for offset in 0..<56 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: candidateSeriesStart) else { continue }
                if let candidateSeriesEnd, day > candidateSeriesEnd { break }
                guard weekdays.contains(calendar.component(.weekday, from: day)) else { continue }
                let occurrenceStart = calendar.date(byAdding: .minute, value: startMinute, to: day) ?? day
                let occurrenceEnd = calendar.date(byAdding: .minute, value: durationMinutes, to: occurrenceStart) ?? occurrenceStart
                if let fixed = blocks.first(where: {
                    $0.kind == .fixed && calendar.isDate($0.start, inSameDayAs: day)
                        && occurrenceStart < $0.end && occurrenceEnd > $0.start
                }) {
                    return "与“\(fixed.title)”冲突"
                }
            }
            return nil
        }

        if let fixed = blocks.first(where: {
            $0.kind == .fixed && calendar.isDate($0.start, inSameDayAs: start)
                && start < $0.end && end > $0.start
        }) {
            if fixed.title.localizedCaseInsensitiveCompare(candidate.title) == .orderedSame,
               fixed.start == start, fixed.end == end {
                return "已存在相同日程“\(fixed.title)”"
            }
            return "与“\(fixed.title)”冲突"
        }

        for rule in recurringSchedules {
            let occurrenceOverride = occurrenceOverrides.first {
                $0.recurringRuleID == rule.id && calendar.isDate($0.occurrenceDate, inSameDayAs: start)
            }
            guard let occurrence = RecurringScheduleEngine.occurrence(
                for: rule,
                on: start,
                override: occurrenceOverride,
                calendar: calendar
            ) else { continue }
            if start < occurrence.end && end > occurrence.start {
                return "与重复日程“\(rule.title)”冲突"
            }
        }
        return nil
    }
}

struct MemoryFact: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var icon: String
    var title: String
    var detail: String
    var source: String
    var confidence: Double
    var status: MemoryStatus
}

struct PlanningRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var detail: String
    var isHard: Bool
    var isEnabled: Bool
}

struct TemporaryState: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var expiresAt: Date
    var workloadMultiplier: Double
}

struct ReplanProposal: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var summary: String
    var changes: [String]
    var reason: String
    var proposedBlocks: [ScheduleBlock]
}

struct LampSnapshot: Codable, Sendable {
    var planItems: [PlanItem]
    var blocks: [ScheduleBlock]
    var memories: [MemoryFact]
    var rules: [PlanningRule]
    var temporaryStates: [TemporaryState]
    var recurringSchedules: [RecurringScheduleRule]
    var occurrenceOverrides: [ScheduleOccurrenceOverride]

    init(
        planItems: [PlanItem], blocks: [ScheduleBlock], memories: [MemoryFact],
        rules: [PlanningRule], temporaryStates: [TemporaryState],
        recurringSchedules: [RecurringScheduleRule] = [],
        occurrenceOverrides: [ScheduleOccurrenceOverride] = []
    ) {
        self.planItems = planItems
        self.blocks = blocks
        self.memories = memories
        self.rules = rules
        self.temporaryStates = temporaryStates
        self.recurringSchedules = recurringSchedules
        self.occurrenceOverrides = occurrenceOverrides
    }

    private enum CodingKeys: String, CodingKey {
        case planItems, blocks, memories, rules, temporaryStates, recurringSchedules, occurrenceOverrides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planItems = try container.decode([PlanItem].self, forKey: .planItems)
        blocks = try container.decode([ScheduleBlock].self, forKey: .blocks)
        memories = try container.decode([MemoryFact].self, forKey: .memories)
        rules = try container.decode([PlanningRule].self, forKey: .rules)
        temporaryStates = try container.decode([TemporaryState].self, forKey: .temporaryStates)
        recurringSchedules = try container.decodeIfPresent([RecurringScheduleRule].self, forKey: .recurringSchedules) ?? []
        occurrenceOverrides = try container.decodeIfPresent([ScheduleOccurrenceOverride].self, forKey: .occurrenceOverrides) ?? []
    }
}

struct OnboardingProfile: Codable, Equatable, Sendable {
    var context: String
    var wakeTime: Date
    var sleepTime: Date
    var scheduleSource: String
}

struct PartialCompletionFeedback: Equatable, Sendable {
    var completedMinutes: Int
    var remainingMinutes: Int
    var note: String
}

struct LampUndoTransaction: Identifiable, Sendable {
    var id = UUID()
    var message: String
    var snapshot: LampSnapshot
}

extension Calendar {
    func date(on day: Date, hour: Int, minute: Int = 0) -> Date {
        date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }
}

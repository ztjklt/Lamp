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

enum ScheduleDeletionScope: String, Codable, CaseIterable, Sendable {
    case singleOccurrence
    case entireSeries
}

enum MemoryStatus: String, Codable, Sendable {
    case inferred, proposed, confirmed
}

enum PlanTimeframe: String, Codable, CaseIterable, Hashable, Sendable {
    case week, month, year

    var title: String {
        switch self {
        case .week: "周"
        case .month: "月"
        case .year: "年"
        }
    }
}

struct PlanningPeriod: Codable, Hashable, Sendable {
    var timeframe: PlanTimeframe
    var anchorDate: Date
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
    var planningPeriod: PlanningPeriod?

    init(
        id: UUID = UUID(), parentID: UUID? = nil, kind: PlanKind, title: String,
        detail: String = "", importance: Int = 3, deadline: Date? = nil,
        estimatedMinutes: Int = 60, remainingMinutes: Int? = nil, progress: Double = 0,
        isPaused: Bool = false, isSplittable: Bool = true,
        preferredPeriod: DayPeriod? = nil, dependencyIDs: [UUID] = [],
        planningPeriod: PlanningPeriod? = nil
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
        self.planningPeriod = planningPeriod
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
    var isSleep: Bool?

    var displayTime: String {
        let prefix = isSleep == true && occurrenceDate.map({ !Calendar.current.isDate($0, inSameDayAs: start) }) == true ? "次日 " : ""
        let endPrefix = Calendar.current.isDate(start, inSameDayAs: end) ? "" : "次日 "
        return "\(prefix)\(start.formatted(date: .omitted, time: .shortened))–\(endPrefix)\(end.formatted(date: .omitted, time: .shortened))"
    }

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
    var isSleep: Bool?
    var startDayOffset: Int?
    var sleepEndMinute: Int?
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

        let actualDay = calendar.date(byAdding: .day, value: rule.startDayOffset ?? 0, to: day) ?? day
        let start = override?.start
            ?? calendar.date(bySettingHour: rule.startMinute / 60, minute: rule.startMinute % 60, second: 0, of: actualDay)
            ?? day
        let endDay = calendar.date(byAdding: .day, value: (rule.sleepEndMinute ?? 1440) <= rule.startMinute ? 1 : 0, to: actualDay) ?? actualDay
        let sleepEnd = rule.sleepEndMinute.flatMap { calendar.date(bySettingHour: $0 / 60, minute: $0 % 60, second: 0, of: endDay) }
        let end = override?.end ?? sleepEnd
            ?? calendar.date(byAdding: .minute, value: rule.durationMinutes, to: start)
            ?? start
        var block = ScheduleBlock(
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
        block.isSleep = rule.isSleep
        return block
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

enum ScheduleDeletionEngine {
    @discardableResult
    static func delete(
        block: ScheduleBlock,
        scope: ScheduleDeletionScope,
        blocks: inout [ScheduleBlock],
        recurringSchedules: inout [RecurringScheduleRule],
        occurrenceOverrides: inout [ScheduleOccurrenceOverride],
        calendar: Calendar = .current
    ) -> Bool {
        if let ruleID = block.recurringRuleID {
            guard recurringSchedules.contains(where: { $0.id == ruleID }) else { return false }
            if scope == .entireSeries {
                recurringSchedules.removeAll { $0.id == ruleID }
                occurrenceOverrides.removeAll { $0.recurringRuleID == ruleID }
                return true
            }
            guard let occurrenceDate = block.occurrenceDate else { return false }
            if let index = occurrenceOverrides.firstIndex(where: {
                $0.recurringRuleID == ruleID && calendar.isDate($0.occurrenceDate, inSameDayAs: occurrenceDate)
            }) {
                occurrenceOverrides[index].state = .missed
                occurrenceOverrides[index].reason = "由你从 Lamp 删除"
                occurrenceOverrides[index].isCancelled = true
            } else {
                occurrenceOverrides.append(ScheduleOccurrenceOverride(
                    recurringRuleID: ruleID,
                    occurrenceDate: occurrenceDate,
                    state: .missed,
                    reason: "由你从 Lamp 删除",
                    isCancelled: true
                ))
            }
            return true
        }
        guard blocks.contains(where: { $0.id == block.id }) else { return false }
        blocks.removeAll { $0.id == block.id }
        return true
    }

    @discardableResult
    static func delete(
        item: PlanItem,
        planItems: inout [PlanItem],
        blocks: inout [ScheduleBlock]
    ) -> Bool {
        guard planItems.contains(where: { $0.id == item.id }) else { return false }
        planItems.removeAll { $0.id == item.id }
        for index in planItems.indices where planItems[index].parentID == item.id {
            planItems[index].parentID = nil
        }
        blocks.removeAll { $0.planItemID == item.id }
        return true
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
    var guidanceEvidence: String?
    var conflictNote: String?
    var needsReview: Bool
    var recurrence: ImageScheduleRecurrence

    init(
        id: UUID = UUID(), title: String, detail: String = "", startAt: Date? = nil,
        endAt: Date? = nil, timezone: String = TimeZone.current.identifier,
        confidence: Double, sourceEvidence: String = "", needsReview: Bool = false,
        guidanceEvidence: String? = nil, conflictNote: String? = nil,
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
        self.guidanceEvidence = guidanceEvidence
        self.conflictNote = conflictNote
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
          for offset in -1...0 {
            let queryDay = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            let occurrenceOverride = occurrenceOverrides.first {
                $0.recurringRuleID == rule.id && calendar.isDate($0.occurrenceDate, inSameDayAs: queryDay)
            }
            guard let occurrence = RecurringScheduleEngine.occurrence(
                for: rule,
                on: queryDay,
                override: occurrenceOverride,
                calendar: calendar
            ) else { continue }
            if start < occurrence.end && end > occurrence.start {
                return "与重复日程“\(rule.title)”冲突"
            }
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

enum ReplanProposalMode: String, Codable, Hashable, Sendable {
    case adjustment
    case dayPlan
    case incompleteTask
    case languageReplan
}

struct ReplanProposal: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var summary: String
    var changes: [String]
    var reason: String
    var proposedBlocks: [ScheduleBlock]
    var mode: ReplanProposalMode = .adjustment
    var sourceFingerprint: String?
    var sourceEventID: UUID?
    var affectedBlockIDs: [UUID] = []
    var temporaryStateTitle: String?
    var previewHash: String?
    var confirmationToken: String?
    var expectedStateVersion: Int?
    var expiresAt: Date?
    var confirmationIdempotencyKey: UUID = UUID()
    var proposedRecurringRule: RecurringScheduleRule?
}

struct AgentPlanDayRequest: Encodable, Sendable {
    struct TimeRange: Codable, Hashable, Sendable {
        var start: Date
        var end: Date
    }

    struct Task: Encodable, Sendable {
        var id: UUID
        var goalId: UUID?
        var title: String
        var detail: String
        var importance: Int
        var deadline: Date?
        var estimatedMinutes: Int
        var remainingMinutes: Int
        var isPaused: Bool
        var isSplittable: Bool
        var minimumSessionMinutes: Int
        var maximumSessionMinutes: Int
        var preferredPeriods: [String]
        var dependencyIds: [UUID]
        var availableWindows: [TimeRange]
    }

    struct ExistingBlock: Encodable, Sendable {
        var id: UUID
        var taskId: UUID?
        var title: String
        var startsAt: Date
        var endsAt: Date
        var kind: String
        var state: String
        var locked: Bool
        var provenance: String
    }

    struct Preferences: Encodable, Sendable {
        var preferredSleepTime: String?
        var preferredWakeTime: String?
        var preferredFocusMinutes: Int
        var preferredBreakMinutes: Int
        var morningStudyPreference: Double
        var eveningStudyPreference: Double
    }

    var schemaVersion: Int = 1
    var requestId: UUID
    var sourceFingerprint: String
    var requestedAt: Date
    var timezone: String
    var locale: String
    var horizon: TimeRange
    var focusMinutesBeforeHorizon: Int = 0
    var tasks: [Task]
    var schedule: [ExistingBlock]
    var preferences: Preferences
}

struct AgentPlanDayResponse: Decodable, Sendable {
    struct Proposal: Decodable, Sendable {
        struct Block: Decodable, Sendable {
            var id: UUID
            var taskId: UUID
            var title: String
            var startsAt: Date
            var endsAt: Date
            var replacesBlockId: UUID?
            var reasonCodes: [String]
        }

        var id: UUID
        var candidateId: UUID
        var title: String
        var summary: String
        var reason: String
        var blocks: [Block]
        var warnings: [String]
    }

    var schemaVersion: Int
    var status: String
    var requestId: UUID
    var sourceFingerprint: String
    var commitRequired: Bool
    var proposal: Proposal?
    var diagnostics: [String]
    var previewHash: String?
    var confirmationToken: String?
    var expectedStateVersion: Int?
    var expiresAt: Date?
}

struct AgentIncompleteReplanRequest: Encodable, Sendable {
    var schemaVersion: Int = 1
    var eventId: UUID
    var sourceFingerprint: String
    var occurredAt: Date
    var timezone: String
    var locale: String
    var planningHorizon: AgentPlanDayRequest.TimeRange
    var taskId: UUID
    var incompleteBlockId: UUID
    var additionalMinutes: Int
    var tasks: [AgentPlanDayRequest.Task]
    var schedule: [AgentPlanDayRequest.ExistingBlock]
    var preferences: AgentPlanDayRequest.Preferences
}

struct AgentIncompleteReplanResponse: Decodable, Sendable {
    struct Proposal: Decodable, Sendable {
        struct Change: Decodable, Sendable {
            struct TimeRange: Decodable, Sendable {
                var start: Date
                var end: Date
            }

            var type: String
            var taskId: UUID?
            var previousBlockId: UUID?
            var proposedBlockId: UUID?
            var previousRange: TimeRange?
            var proposedRange: TimeRange?
            var cost: Double
            var reasonCodes: [String]
        }

        var id: UUID
        var sourceEventId: UUID
        var scope: String
        var title: String
        var summary: String
        var reason: String
        var blocks: [AgentPlanDayResponse.Proposal.Block]
        var changes: [Change]
        var warnings: [String]
    }

    var schemaVersion: Int
    var status: String
    var eventId: UUID
    var sourceFingerprint: String
    var commitRequired: Bool
    var proposal: Proposal?
    var diagnostics: [String]
    var previewHash: String?
    var confirmationToken: String?
    var expectedStateVersion: Int?
    var expiresAt: Date?
}

struct AgentLanguageReplanRequest: Encodable, Sendable {
    var schemaVersion: Int = 1
    var requestId: UUID
    var sourceFingerprint: String
    var requestedAt: Date
    var timezone: String
    var locale: String
    var input: String
    var planningHorizon: AgentPlanDayRequest.TimeRange
    var tasks: [AgentPlanDayRequest.Task]
    var schedule: [AgentPlanDayRequest.ExistingBlock]
    var preferences: AgentPlanDayRequest.Preferences
}

struct AgentLanguageReplanResponse: Decodable, Sendable {
    struct Trace: Decodable, Sendable {
        struct Model: Decodable, Sendable {
            var provider: String
            var model: String
        }

        struct Decision: Decodable, Sendable {
            var intent: String
            var action: String
            var taskId: UUID
            var targetMinutes: Int
            var scope: String
            var temporaryState: String
            var reasonCodes: [String]
            var confidence: Double
        }

        var traceId: UUID
        var model: Model
        var intent: String
        var decision: Decision
        var diagnostics: [String]
    }

    struct Proposal: Decodable, Sendable {
        var id: UUID
        var sourceRequestId: UUID
        var scope: String
        var title: String
        var summary: String
        var reason: String
        var blocks: [AgentPlanDayResponse.Proposal.Block]
        var changes: [AgentIncompleteReplanResponse.Proposal.Change]
        var warnings: [String]
    }

    var schemaVersion: Int
    var status: String
    var requestId: UUID
    var sourceFingerprint: String
    var commitRequired: Bool
    var proposal: Proposal?
    var trace: Trace
    var previewHash: String?
    var confirmationToken: String?
    var expectedStateVersion: Int?
    var expiresAt: Date?
}

struct WeeklyScheduleProposal: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var item: PlanItem
    var weekStart: Date
    var suggestedBlocks: [ScheduleBlock]
    var warnings: [String]
}

struct PlanItemProposal: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var item: PlanItem
    var title: String
    var summary: String
}

struct SchedulePeriodSummary: Equatable, Sendable {
    var totalMinutes: Int
    var focusMinutes: Int
    var completedMinutes: Int
    var fixedEventCount: Int
    var blockCount: Int
    var focusMinutesByDay: [Date: Int]

    var completion: Double {
        guard focusMinutes > 0 else { return 0 }
        return min(1, max(0, Double(completedMinutes) / Double(focusMinutes)))
    }
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

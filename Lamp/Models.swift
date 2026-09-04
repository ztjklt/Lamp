import Foundation
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

    init(
        id: UUID = UUID(), planItemID: UUID? = nil, title: String, start: Date,
        end: Date, kind: BlockKind, state: CompletionState = .planned,
        reason: String = "", provenance: String = "Lamp"
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
    }

    var durationMinutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
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

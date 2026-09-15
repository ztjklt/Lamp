import Foundation
import Testing
@testable import LampCore

@Suite("Planning Engine deterministic fixtures")
struct PlanningEngineTests {
    @Test("midnight sleep belongs to preceding evening and repeats with stable IDs")
    func nightlySleep() throws {
        var rule = RecurringScheduleRule(title: "睡眠", detail: "", startsOn: day, weekdays: Array(1...7), startMinute: 0, durationMinutes: 480, timezone: "UTC")
        rule.isSleep = true
        rule.startDayOffset = 1
        let first = try #require(RecurringScheduleEngine.occurrence(for: rule, on: day, calendar: calendar))
        #expect(first.start == calendar.date(byAdding: .day, value: 1, to: day))
        #expect(first.durationMinutes == 480)
        #expect(first.occurrenceDate == day)
        #expect(first.isSleep == true)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
        let next = try #require(RecurringScheduleEngine.occurrence(for: rule, on: tomorrow, calendar: calendar))
        #expect(first.id != next.id)
        let restored = try JSONDecoder().decode(RecurringScheduleRule.self, from: JSONEncoder().encode(rule))
        #expect(restored.startDayOffset == 1)
        let cancelled = ScheduleOccurrenceOverride(recurringRuleID: rule.id, occurrenceDate: day, state: .missed, isCancelled: true)
        #expect(RecurringScheduleEngine.occurrence(for: rule, on: day, override: cancelled, calendar: calendar) == nil)
        rule.startMinute = 1380
        rule.startDayOffset = 0
        rule.durationMinutes = 540
        let crossMidnight = try #require(RecurringScheduleEngine.occurrence(for: rule, on: day, calendar: calendar))
        #expect(crossMidnight.end == calendar.date(on: tomorrow, hour: 8))
    }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    @Test("sleep survives year boundaries and respects local wake time through daylight saving")
    func sleepCalendarBoundaries() throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(identifier: "America/New_York")!
        let evening = local.date(from: DateComponents(year: 2026, month: 3, day: 7))!
        var rule = RecurringScheduleRule(title: "睡眠", detail: "", startsOn: evening, weekdays: Array(1...7), startMinute: 1380, durationMinutes: 540, timezone: local.timeZone.identifier)
        rule.isSleep = true
        rule.sleepEndMinute = 480
        let occurrence = try #require(RecurringScheduleEngine.occurrence(for: rule, on: evening, calendar: local))
        #expect(local.component(.hour, from: occurrence.end) == 8)
        #expect(occurrence.durationMinutes == 480)
        let yearEnd = local.date(from: DateComponents(year: 2026, month: 12, day: 31))!
        let newYearSleep = try #require(RecurringScheduleEngine.occurrence(for: rule, on: yearEnd, calendar: local))
        #expect(local.component(.year, from: newYearSleep.end) == 2027)
        #expect(RecurringScheduleEngine.occurrence(for: rule, on: local.date(byAdding: .day, value: -1, to: evening)!, calendar: local) == nil)
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        payload.removeValue(forKey: "isSleep")
        payload.removeValue(forKey: "sleepEndMinute")
        let legacy = try JSONDecoder().decode(RecurringScheduleRule.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(legacy.isSleep == nil)
        #expect(legacy.startDayOffset == nil)
    }

    private var day: Date { Date(timeIntervalSince1970: 1_767_225_600) }

    private func context(days: Int = 1, fatigue: Double = 1, protected: [DateInterval] = []) -> PlanningContext {
        PlanningContext(
            horizonStart: calendar.date(on: day, hour: 8),
            horizonEnd: calendar.date(byAdding: .day, value: days, to: calendar.date(on: day, hour: 21))!,
            fatigueMultiplier: fatigue,
            protectedRanges: protected
        )
    }

    @Test("fixed classes and two flexible goals never overlap")
    func fixedAndFlexible() {
        let fixed = [ScheduleBlock(title: "Class", start: calendar.date(on: day, hour: 10), end: calendar.date(on: day, hour: 12), kind: .fixed)]
        let tasks = [PlanItem(kind: .task, title: "Math", estimatedMinutes: 90), PlanItem(kind: .task, title: "AI", estimatedMinutes: 90)]
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(items: tasks, fixed: fixed, context: context())
        #expect(PlanningEngine(calendar: calendar).isFeasible(blocks))
        #expect(blocks.filter { $0.kind == .focus }.count == 2)
    }

    @Test("deadline pressure outranks a low-importance distant task")
    func deadlinePressure() {
        let urgent = PlanItem(kind: .task, title: "Exam", importance: 3, deadline: day.addingTimeInterval(86_400), estimatedMinutes: 60)
        let distant = PlanItem(kind: .task, title: "Reading", importance: 2, deadline: day.addingTimeInterval(30 * 86_400), estimatedMinutes: 60)
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(items: [distant, urgent], fixed: [], context: context())
        #expect(blocks.first?.title == "Exam")
    }

    @Test("partial completion only schedules remaining duration")
    func partialCompletion() {
        let task = PlanItem(kind: .task, title: "Tool Calling", estimatedMinutes: 120, remainingMinutes: 60, progress: 0.5)
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(items: [task], fixed: [], context: context())
        #expect(blocks.reduce(0) { $0 + $1.durationMinutes } == 60)
    }

    @Test("new fixed event invalidates an old slot and causes a move")
    func newFixedEvent() {
        let task = PlanItem(kind: .task, title: "Study", estimatedMinutes: 60, preferredPeriod: .morning)
        let old = ScheduleBlock(planItemID: task.id, title: task.title, start: calendar.date(on: day, hour: 9), end: calendar.date(on: day, hour: 10), kind: .focus)
        let meeting = ScheduleBlock(title: "Meeting", start: calendar.date(on: day, hour: 9), end: calendar.date(on: day, hour: 11), kind: .fixed)
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(items: [task], fixed: [meeting], previous: [old], context: context())
        #expect(blocks.first(where: { $0.planItemID == task.id })?.start != old.start)
        #expect(PlanningEngine(calendar: calendar).isFeasible(blocks))
    }

    @Test("fatigue reduces scheduled workload")
    func fatigue() {
        let tasks = (0..<6).map { PlanItem(kind: .task, title: "Task \($0)", estimatedMinutes: 90) }
        let normal = PlanningEngine(calendar: calendar).makeSchedule(items: tasks, fixed: [], context: context())
        let tired = PlanningEngine(calendar: calendar).makeSchedule(items: tasks, fixed: [], context: context(fatigue: 0.5))
        #expect(tired.reduce(0) { $0 + $1.durationMinutes } < normal.reduce(0) { $0 + $1.durationMinutes })
    }

    @Test("protected time cannot be violated")
    func protectedTime() {
        let protected = DateInterval(start: calendar.date(on: day, hour: 12), end: calendar.date(on: day, hour: 15))
        let task = PlanItem(kind: .task, title: "Deep work", estimatedMinutes: 180)
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(items: [task], fixed: [], context: context(protected: [protected]))
        #expect(PlanningEngine(calendar: calendar).isFeasible(blocks, protected: [protected]))
    }

    @Test("early completion leaves free capacity")
    func earlyCompletion() {
        let finished = PlanItem(kind: .task, title: "Done", estimatedMinutes: 120, remainingMinutes: 0, progress: 1)
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(items: [finished], fixed: [], context: context())
        #expect(blocks.isEmpty)
    }

    @Test("preferred afternoon avoids late evening")
    func rhythmPreference() {
        let task = PlanItem(kind: .task, title: "Calculus", estimatedMinutes: 60, preferredPeriod: .afternoon)
        let block = PlanningEngine(calendar: calendar).makeSchedule(items: [task], fixed: [], context: context()).first
        let hour = block.map { calendar.component(.hour, from: $0.start) }
        #expect(hour != nil && (12..<18).contains(hour!))
    }

    @Test("dependency prevents child placement")
    func dependency() {
        let prerequisite = PlanItem(kind: .task, title: "Basics", estimatedMinutes: 60)
        let child = PlanItem(kind: .task, title: "Advanced", estimatedMinutes: 60, dependencyIDs: [prerequisite.id])
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(items: [prerequisite, child], fixed: [], context: context())
        #expect(blocks.contains { $0.planItemID == prerequisite.id })
        #expect(!blocks.contains { $0.planItemID == child.id })
    }

    @Test("stable prior placement wins an equal-priority tie")
    func scheduleStability() {
        let task = PlanItem(kind: .task, title: "Stable", importance: 3, estimatedMinutes: 60, preferredPeriod: .afternoon)
        let old = ScheduleBlock(planItemID: task.id, title: task.title, start: calendar.date(on: day, hour: 15), end: calendar.date(on: day, hour: 16), kind: .focus)
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(items: [task], fixed: [], previous: [old], context: context())
        #expect(blocks.first?.start == old.start)
    }

    @Test("weekly recurrence expands with a stable occurrence ID")
    func weeklyRecurrenceExpansion() {
        let weekday = calendar.component(.weekday, from: day)
        let rule = RecurringScheduleRule(
            title: "每周研讨课",
            detail: "教室 A",
            startsOn: day,
            weekdays: [weekday],
            startMinute: 9 * 60 + 30,
            durationMinutes: 90,
            timezone: "UTC"
        )
        let first = RecurringScheduleEngine.occurrence(for: rule, on: day, calendar: calendar)
        let repeated = RecurringScheduleEngine.occurrence(for: rule, on: day, calendar: calendar)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!

        #expect(first?.id == repeated?.id)
        #expect(first?.start == calendar.date(on: day, hour: 9, minute: 30))
        #expect(first?.durationMinutes == 90)
        #expect(RecurringScheduleEngine.occurrence(for: rule, on: tomorrow, calendar: calendar) == nil)
    }

    @Test("an occurrence override changes only one weekly instance")
    func weeklyOccurrenceOverride() {
        let weekday = calendar.component(.weekday, from: day)
        let rule = RecurringScheduleRule(
            title: "原课程",
            detail: "",
            startsOn: day,
            weekdays: [weekday],
            startMinute: 10 * 60,
            durationMinutes: 60,
            timezone: "UTC"
        )
        let movedStart = calendar.date(on: day, hour: 14)
        let movedEnd = calendar.date(on: day, hour: 15)
        let override = ScheduleOccurrenceOverride(
            recurringRuleID: rule.id,
            occurrenceDate: day,
            state: .partial,
            title: "本周改期",
            start: movedStart,
            end: movedEnd
        )
        let occurrence = RecurringScheduleEngine.occurrence(for: rule, on: day, override: override, calendar: calendar)
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: day)!
        let nextOccurrence = RecurringScheduleEngine.occurrence(for: rule, on: nextWeek, calendar: calendar)

        #expect(occurrence?.title == "本周改期")
        #expect(occurrence?.state == .partial)
        #expect(occurrence?.start == movedStart)
        #expect(nextOccurrence?.title == "原课程")
        #expect(nextOccurrence?.state == .planned)
    }

    @Test("cancelled recurrence override hides only that instance")
    func cancelledOccurrence() {
        let weekday = calendar.component(.weekday, from: day)
        let rule = RecurringScheduleRule(
            title: "训练",
            detail: "",
            startsOn: day,
            weekdays: [weekday],
            startMinute: 18 * 60,
            durationMinutes: 60,
            timezone: "UTC"
        )
        let override = ScheduleOccurrenceOverride(
            recurringRuleID: rule.id,
            occurrenceDate: day,
            state: .missed,
            isCancelled: true
        )
        #expect(RecurringScheduleEngine.occurrence(for: rule, on: day, override: override, calendar: calendar) == nil)
        #expect(RecurringScheduleEngine.occurrence(
            for: rule,
            on: calendar.date(byAdding: .day, value: 7, to: day)!,
            calendar: calendar
        ) != nil)
    }

    @Test("candidate validator detects duplicates and fixed conflicts")
    func candidateConflictAndDuplicateDetection() {
        let fixed = ScheduleBlock(
            title: "项目会",
            start: calendar.date(on: day, hour: 10),
            end: calendar.date(on: day, hour: 11),
            kind: .fixed
        )
        let duplicate = ImageScheduleCandidate(
            title: fixed.title,
            startAt: fixed.start,
            endAt: fixed.end,
            timezone: "UTC",
            confidence: 0.95
        )
        let overlap = ImageScheduleCandidate(
            title: "客户电话",
            startAt: calendar.date(on: day, hour: 10, minute: 30),
            endAt: calendar.date(on: day, hour: 11, minute: 30),
            timezone: "UTC",
            confidence: 0.9
        )
        #expect(ScheduleCandidateValidator.issue(for: duplicate, blocks: [fixed], recurringSchedules: [], calendar: calendar)?.contains("相同") == true)
        #expect(ScheduleCandidateValidator.issue(for: overlap, blocks: [fixed], recurringSchedules: [], calendar: calendar)?.contains("冲突") == true)
    }

    @Test("legacy snapshots decode with empty recurrence arrays")
    func legacySnapshotCompatibility() throws {
        let original = DemoData.snapshot(now: day, calendar: calendar)
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "recurringSchedules")
        object.removeValue(forKey: "occurrenceOverrides")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(LampSnapshot.self, from: legacyData)

        #expect(decoded.blocks.count == original.blocks.count)
        #expect(decoded.recurringSchedules.isEmpty)
        #expect(decoded.occurrenceOverrides.isEmpty)
    }

    @Test("vision response decodes ISO dates and weekly rules")
    func visionResponseDecoding() throws {
        let json = #"{"analysisID":"8A62C0F3-5D30-46A6-9B9C-C7CA21F70A92","summary":"识别到课程","candidates":[{"id":"0B7D8D22-3FC7-438E-8C22-D4A58FF639B0","title":"设计课","detail":"教室 2","startAt":"2026-09-07T09:00:00Z","endAt":"2026-09-07T10:30:00Z","timezone":"UTC","confidence":0.91,"sourceEvidence":"周一 9:00","needsReview":false,"recurrence":{"kind":"weekly","weekdays":[2],"startsOn":"2026-09-07T00:00:00Z","endsOn":null}}],"warnings":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(ImageScheduleAnalysisResponse.self, from: Data(json.utf8))

        #expect(response.candidates.first?.recurrence.kind == .weekly)
        #expect(response.candidates.first?.recurrence.weekdays == [2])
        #expect(response.candidates.first?.startAt != nil)
        #expect(response.candidates.first?.guidanceEvidence == nil)
        #expect(response.candidates.first?.conflictNote == nil)
    }

    @Test("vision response preserves guidance evidence and conflict notes")
    func guidedVisionResponseDecoding() throws {
        let json = #"{"analysisID":"8A62C0F3-5D30-46A6-9B9C-C7CA21F70A92","summary":"结合说明修正时间","candidates":[{"id":"0B7D8D22-3FC7-438E-8C22-D4A58FF639B0","title":"设计课","detail":"","startAt":"2026-09-09T16:00:00Z","endAt":"2026-09-09T17:00:00Z","timezone":"UTC","confidence":0.91,"sourceEvidence":"图片显示周三 15:00","guidanceEvidence":"实际改为周三 16:00","conflictNote":"说明与图片时间不同","needsReview":true,"recurrence":{"kind":"none","weekdays":[],"startsOn":null,"endsOn":null}}],"warnings":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(ImageScheduleAnalysisResponse.self, from: Data(json.utf8))
        #expect(response.candidates.first?.guidanceEvidence == "实际改为周三 16:00")
        #expect(response.candidates.first?.conflictNote == "说明与图片时间不同")
        #expect(response.candidates.first?.needsReview == true)
    }

    @Test("all one-off schedule categories can be deleted without deleting their plan")
    func deletesAllOneOffBlockKinds() {
        let item = PlanItem(kind: .task, title: "保留任务")
        var blocks = BlockKind.allTestCases.enumerated().map { index, kind in
            ScheduleBlock(
                planItemID: index == 1 ? item.id : nil,
                title: "Block \(index)",
                start: calendar.date(on: day, hour: 8 + index),
                end: calendar.date(on: day, hour: 9 + index),
                kind: kind
            )
        }
        var rules: [RecurringScheduleRule] = []
        var overrides: [ScheduleOccurrenceOverride] = []
        let originals = blocks
        for block in originals {
            #expect(ScheduleDeletionEngine.delete(
                block: block,
                scope: .singleOccurrence,
                blocks: &blocks,
                recurringSchedules: &rules,
                occurrenceOverrides: &overrides,
                calendar: calendar
            ))
        }
        #expect(blocks.isEmpty)
        #expect(item.title == "保留任务")
    }

    @Test("recurring deletion supports one occurrence and the whole series")
    func recurringDeletionScopes() {
        let rule = RecurringScheduleRule(
            title: "每周课程",
            detail: "",
            startsOn: day,
            weekdays: [calendar.component(.weekday, from: day)],
            startMinute: 10 * 60,
            durationMinutes: 60,
            timezone: "UTC"
        )
        let occurrence = RecurringScheduleEngine.occurrence(for: rule, on: day, calendar: calendar)!
        var blocks: [ScheduleBlock] = []
        var rules = [rule]
        var overrides: [ScheduleOccurrenceOverride] = []
        #expect(ScheduleDeletionEngine.delete(
            block: occurrence,
            scope: .singleOccurrence,
            blocks: &blocks,
            recurringSchedules: &rules,
            occurrenceOverrides: &overrides,
            calendar: calendar
        ))
        #expect(rules.count == 1)
        #expect(overrides.first?.isCancelled == true)
        #expect(RecurringScheduleEngine.occurrence(for: rule, on: day, override: overrides.first, calendar: calendar) == nil)

        #expect(ScheduleDeletionEngine.delete(
            block: occurrence,
            scope: .entireSeries,
            blocks: &blocks,
            recurringSchedules: &rules,
            occurrenceOverrides: &overrides,
            calendar: calendar
        ))
        #expect(rules.isEmpty)
        #expect(overrides.isEmpty)
    }

    @Test("deleting a plan removes its blocks and detaches child plans")
    func planDeletionDetachesChildren() {
        let goal = PlanItem(kind: .goal, title: "年度目标")
        let child = PlanItem(parentID: goal.id, kind: .milestone, title: "月度里程碑")
        var items = [goal, child]
        var blocks = [ScheduleBlock(
            planItemID: goal.id,
            title: goal.title,
            start: calendar.date(on: day, hour: 10),
            end: calendar.date(on: day, hour: 11),
            kind: .focus
        )]
        #expect(ScheduleDeletionEngine.delete(item: goal, planItems: &items, blocks: &blocks))
        #expect(items.count == 1)
        #expect(items.first?.parentID == nil)
        #expect(blocks.isEmpty)
    }

    @Test("planning periods round-trip and old items decode without them")
    func planningPeriodCompatibility() throws {
        let original = DemoData.snapshot(now: day, calendar: calendar)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LampSnapshot.self, from: encoded)
        #expect(decoded.planItems.contains { $0.planningPeriod?.timeframe == .year })

        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var items = try #require(object["planItems"] as? [[String: Any]])
        for index in items.indices { items[index].removeValue(forKey: "planningPeriod") }
        object["planItems"] = items
        let legacy = try JSONDecoder().decode(
            LampSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.planItems.allSatisfy { $0.planningPeriod == nil })
    }

    @Test("scheduling never starts before a mid-day horizon")
    func respectsExactHorizonStart() {
        let task = PlanItem(kind: .task, title: "Late request", estimatedMinutes: 60)
        let start = calendar.date(on: day, hour: 15, minute: 20)
        let end = calendar.date(on: day, hour: 21)
        let blocks = PlanningEngine(calendar: calendar).makeSchedule(
            items: [task],
            fixed: [],
            context: PlanningContext(horizonStart: start, horizonEnd: end)
        )
        #expect(blocks.first?.start ?? .distantPast >= start)
    }

    @Test("Agent Core day-plan proposal contract decodes without committing")
    func agentPlanProposalContract() throws {
        let payload = Data("""
        {
          "schemaVersion": 1,
          "status": "proposal",
          "requestId": "10000000-0000-4000-8000-000000000001",
          "sourceFingerprint": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "commitRequired": true,
          "proposal": {
            "id": "10000000-0000-4000-8000-000000000002",
            "candidateId": "10000000-0000-4000-8000-000000000003",
            "title": "今日计划候选",
            "summary": "一项任务",
            "reason": "根据固定日程生成",
            "blocks": [{
              "id": "10000000-0000-4000-8000-000000000004",
              "taskId": "10000000-0000-4000-8000-000000000005",
              "title": "复习高数",
              "startsAt": "2026-09-08T02:00:00Z",
              "endsAt": "2026-09-08T03:00:00Z",
              "replacesBlockId": null,
              "reasonCodes": ["PREFERENCE_MATCH"]
            }],
            "warnings": []
          },
          "diagnostics": []
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(AgentPlanDayResponse.self, from: payload)
        #expect(response.commitRequired)
        #expect(response.status == "proposal")
        #expect(response.proposal?.blocks.first?.title == "复习高数")
    }

    @Test("iOS day-plan request uses the versioned Agent Core field names")
    func agentPlanRequestContract() throws {
        let requestID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let taskID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        let request = AgentPlanDayRequest(
            requestId: requestID,
            sourceFingerprint: String(repeating: "a", count: 64),
            requestedAt: day,
            timezone: "UTC",
            locale: "zh-CN",
            horizon: .init(start: day, end: calendar.date(byAdding: .hour, value: 12, to: day)!),
            tasks: [.init(
                id: taskID, goalId: nil, title: "复习高数", detail: "第二章", importance: 5,
                deadline: nil, estimatedMinutes: 60, remainingMinutes: 60, isPaused: false,
                isSplittable: true, minimumSessionMinutes: 20, maximumSessionMinutes: 90,
                preferredPeriods: ["morning"], dependencyIds: [], availableWindows: []
            )],
            schedule: [],
            preferences: .init(
                preferredSleepTime: "23:30", preferredWakeTime: "08:00",
                preferredFocusMinutes: 50, preferredBreakMinutes: 10,
                morningStudyPreference: 0.8, eveningStudyPreference: 0.2
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try #require(JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["requestId"] as? String == requestID.uuidString)
        #expect(object["focusMinutesBeforeHorizon"] as? Int == 0)
        #expect((object["tasks"] as? [[String: Any]])?.first?["remainingMinutes"] as? Int == 60)
    }

    @Test("Agent Core incomplete-replan proposal carries event, replacement, and explanation")
    func incompleteReplanProposalContract() throws {
        let payload = Data("""
        {
          "schemaVersion": 1,
          "status": "proposal",
          "eventId": "20000000-0000-4000-8000-000000000001",
          "sourceFingerprint": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "commitRequired": true,
          "proposal": {
            "id": "20000000-0000-4000-8000-000000000002",
            "sourceEventId": "20000000-0000-4000-8000-000000000001",
            "scope": "local",
            "title": "未完成任务的调整候选",
            "summary": "只调整一项",
            "reason": "未完成需要重新安放",
            "blocks": [{
              "id": "20000000-0000-4000-8000-000000000003",
              "taskId": "20000000-0000-4000-8000-000000000004",
              "title": "复习高数",
              "startsAt": "2026-09-08T13:00:00Z",
              "endsAt": "2026-09-08T14:00:00Z",
              "replacesBlockId": "20000000-0000-4000-8000-000000000005",
              "reasonCodes": ["TASK_INCOMPLETE_REQUIRES_REALLOCATION", "BLOCK_MOVED"]
            }],
            "changes": [{
              "type": "MOVE",
              "taskId": "20000000-0000-4000-8000-000000000004",
              "previousBlockId": "20000000-0000-4000-8000-000000000005",
              "proposedBlockId": "20000000-0000-4000-8000-000000000003",
              "previousRange": { "start": "2026-09-08T11:00:00Z", "end": "2026-09-08T12:00:00Z" },
              "proposedRange": { "start": "2026-09-08T13:00:00Z", "end": "2026-09-08T14:00:00Z" },
              "cost": 2,
              "reasonCodes": ["TASK_INCOMPLETE_REQUIRES_REALLOCATION", "BLOCK_MOVED"]
            }],
            "warnings": []
          },
          "diagnostics": ["local:success"]
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(AgentIncompleteReplanResponse.self, from: payload)
        #expect(response.commitRequired)
        #expect(response.proposal?.sourceEventId == response.eventId)
        #expect(response.proposal?.blocks.first?.replacesBlockId?.uuidString == "20000000-0000-4000-8000-000000000005")
        #expect(response.proposal?.changes.first?.type == "MOVE")
    }

    @Test("iOS incomplete-replan request keeps one event id and source fingerprint")
    func incompleteReplanRequestContract() throws {
        let eventID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let taskID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
        let blockID = UUID(uuidString: "20000000-0000-4000-8000-000000000003")!
        let request = AgentIncompleteReplanRequest(
            eventId: eventID,
            sourceFingerprint: String(repeating: "b", count: 64),
            occurredAt: day,
            timezone: "UTC",
            locale: "zh-CN",
            planningHorizon: .init(start: day, end: calendar.date(byAdding: .day, value: 3, to: day)!),
            taskId: taskID,
            incompleteBlockId: blockID,
            additionalMinutes: 60,
            tasks: [.init(
                id: taskID, goalId: nil, title: "复习高数", detail: "第二章", importance: 5,
                deadline: nil, estimatedMinutes: 60, remainingMinutes: 60, isPaused: false,
                isSplittable: true, minimumSessionMinutes: 15, maximumSessionMinutes: 90,
                preferredPeriods: ["evening"], dependencyIds: [], availableWindows: []
            )],
            schedule: [.init(
                id: blockID, taskId: taskID, title: "复习高数", startsAt: day,
                endsAt: calendar.date(byAdding: .hour, value: 1, to: day)!, kind: "focus",
                state: "missed", locked: false, provenance: "Lamp"
            )],
            preferences: .init(
                preferredSleepTime: nil, preferredWakeTime: nil, preferredFocusMinutes: 50,
                preferredBreakMinutes: 10, morningStudyPreference: 0.2, eveningStudyPreference: 0.8
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try #require(JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["eventId"] as? String == eventID.uuidString)
        #expect(object["incompleteBlockId"] as? String == blockID.uuidString)
        #expect(object["sourceFingerprint"] as? String == String(repeating: "b", count: 64))
    }

    @Test("Agent Core language-replan response exposes model decision and Planner changes")
    func languageReplanResponseContract() throws {
        let payload = Data("""
        {
          "schemaVersion": 1,
          "status": "proposal",
          "requestId": "50000000-0000-4000-8000-000000000001",
          "sourceFingerprint": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
          "commitRequired": true,
          "proposal": {
            "id": "50000000-0000-4000-8000-000000000002",
            "sourceRequestId": "50000000-0000-4000-8000-000000000001",
            "scope": "local",
            "title": "让今天的“复习高数”轻一点",
            "summary": "模型理解后由 Planner 调整",
            "reason": "临时疲惫",
            "blocks": [{
              "id": "50000000-0000-4000-8000-000000000003",
              "taskId": "50000000-0000-4000-8000-000000000004",
              "title": "复习高数",
              "startsAt": "2026-09-08T12:00:00Z",
              "endsAt": "2026-09-08T12:30:00Z",
              "replacesBlockId": "50000000-0000-4000-8000-000000000005",
              "reasonCodes": ["USER_REQUESTED_REPLAN", "BLOCK_RESIZED"]
            }],
            "changes": [{
              "type": "RESIZE",
              "taskId": "50000000-0000-4000-8000-000000000004",
              "previousBlockId": "50000000-0000-4000-8000-000000000005",
              "proposedBlockId": "50000000-0000-4000-8000-000000000003",
              "previousRange": { "start": "2026-09-08T12:00:00Z", "end": "2026-09-08T13:00:00Z" },
              "proposedRange": { "start": "2026-09-08T12:00:00Z", "end": "2026-09-08T12:30:00Z" },
              "cost": 1,
              "reasonCodes": ["USER_REQUESTED_REPLAN", "BLOCK_RESIZED"]
            }],
            "warnings": []
          },
          "trace": {
            "traceId": "50000000-0000-4000-8000-000000000006",
            "model": { "provider": "deepseek", "model": "deepseek-chat" },
            "intent": "replan_schedule",
            "decision": {
              "intent": "replan_schedule",
              "action": "reduce_task_workload",
              "taskId": "50000000-0000-4000-8000-000000000004",
              "targetMinutes": 30,
              "scope": "day",
              "temporaryState": "tired",
              "reasonCodes": ["USER_REPORTED_FATIGUE"],
              "confidence": 0.96
            },
            "diagnostics": ["local:success"]
          }
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(AgentLanguageReplanResponse.self, from: payload)
        #expect(response.commitRequired)
        #expect(response.trace.intent == "replan_schedule")
        #expect(response.trace.decision.action == "reduce_task_workload")
        #expect(response.trace.decision.targetMinutes == 30)
        #expect(response.proposal?.blocks.first?.replacesBlockId?.uuidString == "50000000-0000-4000-8000-000000000005")
        #expect(response.proposal?.changes.first?.type == "RESIZE")
    }

    @Test("iOS language-replan request preserves the natural language and state fingerprint")
    func languageReplanRequestContract() throws {
        let requestID = UUID(uuidString: "50000000-0000-4000-8000-000000000001")!
        let taskID = UUID(uuidString: "50000000-0000-4000-8000-000000000002")!
        let blockID = UUID(uuidString: "50000000-0000-4000-8000-000000000003")!
        let end = calendar.date(byAdding: .hour, value: 4, to: day)!
        let request = AgentLanguageReplanRequest(
            requestId: requestID,
            sourceFingerprint: String(repeating: "c", count: 64),
            requestedAt: day,
            timezone: "UTC",
            locale: "zh-CN",
            input: "今天有点累，高数少学一点。",
            planningHorizon: .init(start: day, end: end),
            tasks: [.init(
                id: taskID, goalId: nil, title: "复习高数", detail: "第二章", importance: 5,
                deadline: nil, estimatedMinutes: 60, remainingMinutes: 60, isPaused: false,
                isSplittable: true, minimumSessionMinutes: 15, maximumSessionMinutes: 90,
                preferredPeriods: ["evening"], dependencyIds: [], availableWindows: []
            )],
            schedule: [.init(
                id: blockID, taskId: taskID, title: "复习高数", startsAt: day, endsAt: end,
                kind: "focus", state: "planned", locked: false, provenance: "Lamp"
            )],
            preferences: .init(
                preferredSleepTime: nil, preferredWakeTime: nil, preferredFocusMinutes: 50,
                preferredBreakMinutes: 10, morningStudyPreference: 0.2, eveningStudyPreference: 0.8
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try #require(JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["requestId"] as? String == requestID.uuidString)
        #expect(object["input"] as? String == "今天有点累，高数少学一点。")
        #expect(object["sourceFingerprint"] as? String == String(repeating: "c", count: 64))
    }
}

private extension BlockKind {
    static let allTestCases: [BlockKind] = [.fixed, .focus, .breakTime, .free]
}

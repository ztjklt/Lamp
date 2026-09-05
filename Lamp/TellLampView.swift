import PhotosUI
import SwiftUI
import UIKit

private enum TellLampPhase: Equatable {
    case idle
    case preparingImage
    case analyzingImage
    case sending
    case answered
    case failed
}

struct TellLampView: View {
    @EnvironmentObject private var store: LampStore
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speech = SpeechService()
    @State private var text = ""
    @State private var lastSubmitted = ""
    @State private var response: String?
    @State private var phase: TellLampPhase = .idle
    @State private var photo: PhotosPickerItem?
    @State private var previewImage: UIImage?
    @State private var preparedImage: ImageIngestionService.PreparedImage?
    @State private var analysis: ImageScheduleAnalysisResponse?
    @State private var candidates: [ImageScheduleCandidate] = []
    @State private var selectedCandidateIDs: Set<UUID> = []
    @State private var fallbackOCRLines: [String] = []
    @State private var editingCandidate: ImageScheduleCandidate?
    @FocusState private var focused: Bool

    private let suggestions = ["我今天很累", "明天下午 3 点开会", "我想系统学习 AI"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    LampLight(size: speech.isRecording ? 72 : 54)
                        .frame(height: 82)
                        .animation(.spring(response: 0.42, dampingFraction: 0.76), value: speech.isRecording)

                    VStack(spacing: 4) {
                        Text(headerTitle).font(.title.bold())
                        Text("目标、变动、感受，或者一张日程图片。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }

                    if let response { responseCard(response) }
                    if previewImage != nil { imagePreviewCard }
                    if analysis != nil { scheduleReview }
                    if !fallbackOCRLines.isEmpty { fallbackOCRCard }

                    TextField("例如：我今晚很累，把计划放轻一点", text: $text, axis: .vertical)
                        .lineLimit(3...7)
                        .focused($focused)
                        .padding(16)
                        .background(LampTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(LampTheme.hairline))
                        .accessibilityIdentifier("tellLamp.input")

                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button(suggestion) {
                                    text = suggestion
                                    focused = true
                                }
                                .buttonStyle(.lamp)
                                .accessibilityIdentifier("tellLamp.suggestion.\(suggestions.firstIndex(of: suggestion) ?? 0)")
                            }
                        }
                    }
                    .scrollIndicators(.hidden)

                    actionRow

                    if let error = speech.errorMessage {
                        VStack(spacing: 8) {
                            Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                            Button("打开系统设置") { openSettings() }
                                .font(.caption.weight(.semibold))
                        }
                    }

                    if phase == .failed {
                        HStack(spacing: 10) {
                            if preparedImage != nil {
                                Button("重试图片分析") { retryImageAnalysis() }
                                    .buttonStyle(.lamp)
                                    .accessibilityIdentifier("tellLamp.retryImage")
                            }
                            if !lastSubmitted.isEmpty {
                                Button("重试文字发送") { send(lastSubmitted) }
                                    .buttonStyle(.lamp)
                                    .accessibilityIdentifier("tellLamp.retry")
                            }
                        }
                    }

                    Text("图片只临时用于识别；确认前不会写入时间线。")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                .padding(22)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .lampPage()
            .navigationTitle("告诉 Lamp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        speech.stop()
                        dismiss()
                    }
                    .accessibilityIdentifier("tellLamp.done")
                }
            }
            .onChange(of: speech.transcript) { _, value in
                if !value.isEmpty { text = value }
            }
            .onChange(of: photo) { _, item in analyze(item) }
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-mock-image-analysis"), analysis == nil {
                    loadMockAnalysis()
                }
            }
            .sheet(item: $editingCandidate) { candidate in
                ImageScheduleCandidateEditor(candidate: candidate) { updated in
                    guard let index = candidates.firstIndex(where: { $0.id == updated.id }) else { return }
                    candidates[index] = updated
                    if store.conflictDescription(for: updated) == nil {
                        selectedCandidateIDs.insert(updated.id)
                    }
                }
            }
            .sensoryFeedback(.success, trigger: phase == .answered)
        }
    }

    private var isBusy: Bool {
        phase == .sending || phase == .preparingImage || phase == .analyzingImage
    }

    private var headerTitle: String {
        if speech.isRecording { return "我在听" }
        switch phase {
        case .preparingImage: return "正在准备图片"
        case .analyzingImage: return "DeepSeek 正在整理日程"
        case .sending: return "正在理解"
        default: return "告诉 Lamp"
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $photo, matching: .images) {
                Label("图片日程", systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .lampGlass(.regular, cornerRadius: 22)
            .disabled(isBusy)
            .accessibilityIdentifier("tellLamp.photo")

            Button { speech.toggle() } label: {
                Label(speech.isRecording ? "停止" : "说话", systemImage: speech.isRecording ? "stop.fill" : "mic.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(speech.isRecording ? .red : LampTheme.ink)
            .lampGlass(.regular, cornerRadius: 22)
            .disabled(isBusy)
            .accessibilityIdentifier("tellLamp.voice")

            Button { send(text) } label: {
                Group {
                    if phase == .sending {
                        ProgressView().tint(.white)
                    } else {
                        Label("发送", systemImage: "arrow.up")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.lampProminent)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
            .accessibilityIdentifier("tellLamp.send")
        }
    }

    private func responseCard(_ response: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if isBusy {
                ProgressView().tint(LampTheme.amber)
            } else {
                Image(systemName: phase == .failed ? "exclamationmark.triangle.fill" : "sparkles")
                    .foregroundStyle(phase == .failed ? LampTheme.danger : LampTheme.amber)
            }
            Text(response).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(15)
        .background(LampTheme.amber.opacity(0.11), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("tellLamp.response")
    }

    private var imagePreviewCard: some View {
        LampCard {
            HStack(spacing: 14) {
                if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("待分析的日程图片").font(.headline)
                    Text(isBusy ? "正在安全处理，原图不会被保存" : "可重新分析或取消")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { cancelImage() }
                    .font(.subheadline.weight(.semibold))
                    .disabled(isBusy)
                    .accessibilityIdentifier("tellLamp.cancelImage")
            }
        }
    }

    private var scheduleReview: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let analysis {
                LampCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("AI 概括", systemImage: "sparkles.rectangle.stack")
                            .font(.headline)
                        Text(analysis.summary).font(.subheadline)
                        ForEach(analysis.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(LampTheme.amber)
                        }
                    }
                }
            }

            SectionLabel(title: "日程候选", trailing: "已选 \(selectedCandidateIDs.count)/\(candidates.count)")
                .accessibilityIdentifier("tellLamp.imageReview")
            ForEach(candidates) { candidate in candidateCard(candidate) }

            Button { importSelectedCandidates() } label: {
                Label("确认并加入时间线", systemImage: "calendar.badge.checkmark")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.lampProminent)
            .disabled(!canImport)
            .accessibilityIdentifier("tellLamp.importImage")

            if !canImport, !selectedCandidateIDs.isEmpty {
                Text("请先编辑带有红色提示的候选，或取消选择后再导入。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func candidateCard(_ candidate: ImageScheduleCandidate) -> some View {
        let issue = store.conflictDescription(for: candidate)
        let isSelected = selectedCandidateIDs.contains(candidate.id)
        return LampCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Button {
                        if isSelected { selectedCandidateIDs.remove(candidate.id) }
                        else { selectedCandidateIDs.insert(candidate.id) }
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(isSelected ? LampTheme.amber : .secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("imageCandidate.select.\(candidate.id.uuidString)")

                    VStack(alignment: .leading, spacing: 5) {
                        Text(candidate.title.isEmpty ? "未命名日程" : candidate.title).font(.headline)
                        Text(candidateTimeText(candidate))
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        if candidate.recurrence.kind == .weekly {
                            Label(recurrenceText(candidate.recurrence), systemImage: "repeat")
                                .font(.caption).foregroundStyle(LampTheme.amber)
                        }
                    }
                    Spacer()
                    confidenceBadge(candidate.confidence, needsReview: candidate.needsReview)
                }

                if !candidate.sourceEvidence.isEmpty {
                    Text("依据：\(candidate.sourceEvidence)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if let issue {
                    Label(issue, systemImage: "exclamationmark.octagon.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(LampTheme.danger)
                        .accessibilityIdentifier("imageCandidate.conflict.\(candidate.id.uuidString)")
                }
                Button("编辑并确认") { editingCandidate = candidate }
                    .buttonStyle(.lamp)
                    .accessibilityIdentifier("imageCandidate.edit.\(candidate.id.uuidString)")
            }
        }
        .opacity(isSelected ? 1 : 0.58)
    }

    private var fallbackOCRCard: some View {
        LampCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("本机只读识别", systemImage: "text.viewfinder").font(.headline)
                Text("AI 暂时不可用，以下文字不会自动生成日程。联网后可重试图片分析。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(fallbackOCRLines.prefix(8).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.subheadline)
                    Divider()
                }
            }
        }
    }

    private var canImport: Bool {
        let selected = candidates.filter { selectedCandidateIDs.contains($0.id) }
        return !selected.isEmpty && selected.allSatisfy { store.conflictDescription(for: $0) == nil }
    }

    private func analyze(_ item: PhotosPickerItem?) {
        guard let item else { return }
        speech.stop()
        phase = .preparingImage
        response = "正在压缩并保护图片隐私…"
        analysis = nil
        candidates = []
        selectedCandidateIDs = []
        fallbackOCRLines = []
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ImageIngestionService.IngestionError.invalidImage
                }
                previewImage = UIImage(data: data)
                let prepared = try await ImageIngestionService.prepareForVision(data)
                preparedImage = prepared
                phase = .analyzingImage
                response = "正在识别文字、日期和重复规则…"
                applyAnalysis(try await AgentAPIClient.analyzeScheduleImage(prepared))
            } catch {
                phase = .failed
                response = error.localizedDescription
                if let data = try? await item.loadTransferable(type: Data.self) {
                    fallbackOCRLines = (try? await ImageIngestionService.recognizeText(in: data)) ?? []
                }
            }
        }
    }

    private func retryImageAnalysis() {
        guard let preparedImage else { return }
        phase = .analyzingImage
        response = "正在重新分析图片…"
        fallbackOCRLines = []
        Task {
            do { applyAnalysis(try await AgentAPIClient.analyzeScheduleImage(preparedImage)) }
            catch {
                phase = .failed
                response = error.localizedDescription
            }
        }
    }

    private func applyAnalysis(_ result: ImageScheduleAnalysisResponse) {
        analysis = result
        candidates = result.candidates
        selectedCandidateIDs = Set(result.candidates.filter {
            store.conflictDescription(for: $0) == nil
        }.map(\.id))
        phase = .answered
        response = result.candidates.isEmpty
            ? "没有找到可以确认的日程，请换一张更完整的图片。"
            : "已整理出 \(result.candidates.count) 项候选。检查后再加入时间线。"
    }

    private func importSelectedCandidates() {
        let selected = candidates.filter { selectedCandidateIDs.contains($0.id) }
        guard !store.importScheduleCandidates(selected).isEmpty else {
            response = "没有可导入的候选，请先补全时间或解决冲突。"
            phase = .failed
            return
        }
        router.destination = .today
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            store.highlightedBlockIDs = []
        }
    }

    private func cancelImage() {
        photo = nil
        previewImage = nil
        preparedImage = nil
        analysis = nil
        candidates = []
        selectedCandidateIDs = []
        fallbackOCRLines = []
        response = nil
        phase = .idle
    }

    private func send(_ value: String) {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        speech.stop()
        lastSubmitted = input
        focused = false
        phase = .sending
        response = nil
        Task {
            response = await store.processWithAgent(input: input)
            phase = .answered
            text = ""
            if store.pendingReplan != nil { dismiss() }
        }
    }

    private func candidateTimeText(_ candidate: ImageScheduleCandidate) -> String {
        guard let start = candidate.startAt, let end = candidate.endAt else { return "时间待补充" }
        return "\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    private func recurrenceText(_ recurrence: ImageScheduleRecurrence) -> String {
        let names = [1: "周日", 2: "周一", 3: "周二", 4: "周三", 5: "周四", 6: "周五", 7: "周六"]
        let days = recurrence.weekdays.sorted().compactMap { names[$0] }.joined(separator: "、")
        let ending = recurrence.endsOn?.formatted(date: .abbreviated, time: .omitted) ?? "无结束日期"
        return "每周 \(days.isEmpty ? "待选择" : days) · 至 \(ending)"
    }

    private func confidenceBadge(_ confidence: Double, needsReview: Bool) -> some View {
        Text(needsReview ? "需确认" : "\(Int(max(0, min(1, confidence)) * 100))%")
            .font(.caption2.weight(.bold))
            .foregroundStyle(needsReview ? LampTheme.amber : LampTheme.sage)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background((needsReview ? LampTheme.amber : LampTheme.sage).opacity(0.12), in: Capsule())
    }

    private func loadMockAnalysis() {
        let today = Calendar.current.startOfDay(for: .now)
        let start = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: today) ?? .now
        let end = Calendar.current.date(byAdding: .hour, value: 1, to: start) ?? start
        let candidate = ImageScheduleCandidate(
            title: "产品评审",
            detail: "讨论 Lamp 图片日程体验",
            startAt: start,
            endAt: end,
            confidence: 0.94,
            sourceEvidence: "明天下午产品评审 1 小时"
        )
        previewImage = UIImage(systemName: "calendar")
        applyAnalysis(ImageScheduleAnalysisResponse(
            analysisID: UUID(),
            summary: "图片包含一项今晚的产品评审安排。",
            candidates: [candidate],
            warnings: []
        ))
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct ImageScheduleCandidateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ImageScheduleCandidate
    @State private var start: Date
    @State private var end: Date
    @State private var hasEndDate: Bool
    var onSave: (ImageScheduleCandidate) -> Void

    init(candidate: ImageScheduleCandidate, onSave: @escaping (ImageScheduleCandidate) -> Void) {
        _draft = State(initialValue: candidate)
        let fallbackStart = candidate.startAt ?? Date.now
        _start = State(initialValue: fallbackStart)
        _end = State(initialValue: candidate.endAt ?? fallbackStart.addingTimeInterval(3_600))
        _hasEndDate = State(initialValue: candidate.recurrence.endsOn != nil)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("日程") {
                    TextField("标题", text: $draft.title)
                        .accessibilityIdentifier("imageCandidateEditor.title")
                    TextField("说明", text: $draft.detail, axis: .vertical).lineLimit(2...5)
                    DatePicker("开始", selection: $start)
                    DatePicker("结束", selection: $end)
                }

                Section("重复") {
                    Picker("类型", selection: $draft.recurrence.kind) {
                        Text("不重复").tag(ImageScheduleRecurrenceKind.none)
                        Text("每周").tag(ImageScheduleRecurrenceKind.weekly)
                    }
                    .pickerStyle(.segmented)

                    if draft.recurrence.kind == .weekly {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(Array(zip([2, 3, 4, 5, 6, 7, 1], ["一", "二", "三", "四", "五", "六", "日"])), id: \.0) { weekday, name in
                                    Button(name) { toggleWeekday(weekday) }
                                        .buttonStyle(.bordered)
                                        .tint(draft.recurrence.weekdays.contains(weekday) ? LampTheme.amber : .secondary)
                                }
                            }
                        }
                        Toggle("设置结束日期", isOn: $hasEndDate)
                        if hasEndDate {
                            DatePicker(
                                "结束日期",
                                selection: Binding(
                                    get: { draft.recurrence.endsOn ?? start },
                                    set: { draft.recurrence.endsOn = $0 }
                                ),
                                displayedComponents: .date
                            )
                        } else {
                            LabeledContent("持续", value: "无结束日期")
                        }
                    }
                }

                if !draft.sourceEvidence.isEmpty {
                    Section("图片依据") { Text(draft.sourceEvidence).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("确认日程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        draft.startAt = start
                        draft.endAt = end
                        draft.timezone = TimeZone.current.identifier
                        draft.needsReview = false
                        if draft.recurrence.kind == .weekly {
                            if draft.recurrence.weekdays.isEmpty {
                                draft.recurrence.weekdays = [Calendar.current.component(.weekday, from: start)]
                            }
                            draft.recurrence.startsOn = draft.recurrence.startsOn ?? start
                            if !hasEndDate { draft.recurrence.endsOn = nil }
                        } else {
                            draft.recurrence = .none
                        }
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || end <= start)
                    .accessibilityIdentifier("imageCandidateEditor.save")
                }
            }
        }
    }

    private func toggleWeekday(_ weekday: Int) {
        if let index = draft.recurrence.weekdays.firstIndex(of: weekday) {
            draft.recurrence.weekdays.remove(at: index)
        } else {
            draft.recurrence.weekdays.append(weekday)
        }
    }
}

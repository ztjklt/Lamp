import PhotosUI
import SwiftUI
import UIKit

private enum TellLampPhase: Equatable {
    case idle
    case recognizing
    case sending
    case answered
    case failed
}

struct TellLampView: View {
    @EnvironmentObject private var store: LampStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speech = SpeechService()
    @State private var text = ""
    @State private var lastSubmitted = ""
    @State private var response: String?
    @State private var phase: TellLampPhase = .idle
    @State private var photo: PhotosPickerItem?
    @State private var recognizedLines: [String] = []
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
                        Text("目标、变动、感受，或者一张课表截图。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }

                    if let response { responseCard(response) }
                    if !recognizedLines.isEmpty { recognitionReview }

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

                    HStack(spacing: 10) {
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label("图片", systemImage: "photo")
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
                        .disabled(phase == .sending || phase == .recognizing)
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

                    if let error = speech.errorMessage {
                        VStack(spacing: 8) {
                            Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                            Button("打开系统设置") { openSettings() }
                                .font(.caption.weight(.semibold))
                        }
                    }

                    if phase == .failed, !lastSubmitted.isEmpty {
                        Button("重试上一次发送") { send(lastSubmitted) }
                            .buttonStyle(.lamp)
                            .accessibilityIdentifier("tellLamp.retry")
                    }

                    Text("重要改动会先预览；普通低风险操作可撤销。")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                .padding(22)
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
            .onChange(of: photo) { _, item in recognize(item) }
            .sensoryFeedback(.success, trigger: phase == .answered)
        }
    }

    private var isBusy: Bool { phase == .sending || phase == .recognizing }

    private var headerTitle: String {
        if speech.isRecording { return "我在听" }
        if phase == .recognizing { return "正在识别" }
        if phase == .sending { return "正在理解" }
        return "告诉 Lamp"
    }

    private func responseCard(_ response: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: phase == .failed ? "exclamationmark.triangle.fill" : "sparkles")
                .foregroundStyle(phase == .failed ? LampTheme.danger : LampTheme.amber)
            Text(response).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(15)
        .background(LampTheme.amber.opacity(0.11), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("tellLamp.response")
    }

    private var recognitionReview: some View {
        LampCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("识别候选", systemImage: "text.viewfinder")
                        .font(.headline)
                    Spacer()
                    Text("需确认").font(.caption.weight(.semibold)).foregroundStyle(LampTheme.amber)
                }
                ForEach(Array(recognizedLines.prefix(8).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    if line != recognizedLines.prefix(8).last { Divider() }
                }
                HStack(spacing: 10) {
                    Button("放弃") {
                        recognizedLines = []
                        photo = nil
                        response = nil
                        phase = .idle
                    }
                    .buttonStyle(.lamp)
                    Button("确认导入") {
                        store.importOCRLines(recognizedLines)
                        recognizedLines = []
                        photo = nil
                        response = "候选内容已转成事项并加入计划。"
                        phase = .answered
                    }
                    .buttonStyle(.lampProminent)
                    .accessibilityIdentifier("tellLamp.importImage")
                }
            }
        }
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
            let answer = await store.processWithAgent(input: input)
            response = answer
            phase = .answered
            text = ""
            if store.pendingReplan != nil { dismiss() }
        }
    }

    private func recognize(_ item: PhotosPickerItem?) {
        guard let item else { return }
        phase = .recognizing
        response = "正在识别图片中的日程…"
        recognizedLines = []
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ImageIngestionService.IngestionError.invalidImage
                }
                let lines = try await ImageIngestionService.recognizeText(in: data)
                if lines.isEmpty {
                    phase = .failed
                    response = "没有识别到清晰文字。可以换一张更完整、正面的截图。"
                } else {
                    recognizedLines = lines
                    phase = .answered
                    response = "识别到 \(lines.count) 行内容。请确认后再导入，现有安排不会被覆盖。"
                }
            } catch {
                phase = .failed
                response = "图片识别失败了，原输入仍然保留。你可以重试或直接输入文字。"
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

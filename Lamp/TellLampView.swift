import PhotosUI
import SwiftUI

struct TellLampView: View {
    @EnvironmentObject private var store: LampStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speech = SpeechService()
    @State private var text = ""
    @State private var response: String?
    @State private var isSending = false
    @State private var photo: PhotosPickerItem?
    @FocusState private var focused: Bool

    private let suggestions = ["我今天很累", "明天下午 3 点开会", "我想系统学习 AI"]

    var body: some View {
        NavigationStack {
            ZStack {
                LampTheme.background.ignoresSafeArea()
                VStack(spacing: 18) {
                    LampLight(size: speech.isRecording ? 72 : 54)
                        .animation(.spring, value: speech.isRecording)
                    VStack(spacing: 4) {
                        Text(speech.isRecording ? "我在听" : "告诉 Lamp")
                            .font(.title.bold())
                        Text("目标、变动、感受，或者一张课表截图。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }

                    if let response {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "sparkles").foregroundStyle(LampTheme.amber)
                            Text(response).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(15).background(LampTheme.amberSoft.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
                    }

                    TextField("例如：我今晚很累，把计划放轻一点", text: $text, axis: .vertical)
                        .lineLimit(3...6).focused($focused)
                        .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.black.opacity(0.06)))

                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button(suggestion) { text = suggestion }
                                    .buttonStyle(.bordered).tint(LampTheme.ink)
                            }
                        }
                    }.scrollIndicators(.hidden)

                    HStack(spacing: 12) {
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label("图片", systemImage: "photo").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(LampTheme.ink)

                        Button { speech.toggle() } label: {
                            Label(speech.isRecording ? "停止" : "说话", systemImage: speech.isRecording ? "stop.fill" : "mic.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(speech.isRecording ? .red : LampTheme.ink)

                        Button { send() } label: {
                            if isSending {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Label("发送", systemImage: "arrow.up").frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent).tint(LampTheme.ink).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
                    }
                    .controlSize(.large)

                    if let error = speech.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                    Spacer()
                    Text("重要改动会先预览；普通低风险操作可撤销。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(22)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .onChange(of: speech.transcript) { _, value in if !value.isEmpty { text = value } }
            .onChange(of: photo) { _, item in
                guard item != nil else { return }
                response = "正在识别图片中的日程…"
                Task {
                    do {
                        guard let data = try await item?.loadTransferable(type: Data.self) else { return }
                        let lines = try await ImageIngestionService.recognizeText(in: data)
                        let sample = lines.prefix(3).joined(separator: "、")
                        response = lines.isEmpty
                            ? "没有识别到清晰文字。可以换一张更完整、正面的截图。"
                            : "识别到 \(lines.count) 行内容：\(sample)。这些会先作为候选日程复核，不会直接覆盖现有安排。"
                    } catch {
                        response = "图片识别失败了。你可以重试，或直接用文字告诉我。"
                    }
                }
            }
        }
    }

    private func send() {
        speech.stop()
        let input = text
        text = ""
        focused = false
        isSending = true
        Task {
            response = await store.processWithAgent(input: input)
            isSending = false
            if store.pendingReplan != nil { dismiss() }
        }
    }
}

import EventKit
import SwiftUI
import UIKit

struct MemoryView: View {
    @EnvironmentObject private var store: LampStore
    var showPrivacy: () -> Void = {}
    @State private var editingMemory: MemoryFact?
    @State private var deletingMemory: MemoryFact?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LampTheme.Spacing.section) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lamp 了解的你").font(.largeTitle.bold())
                        Text("所有长期记忆都由你掌控。")
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        summary("\(store.memories.count)", "条记忆")
                        summary("\(store.rules.filter(\.isEnabled).count)", "条规则")
                        summary("本机", "当前数据")
                    }
                    SectionLabel(title: "记忆")
                    if store.memories.isEmpty {
                        LampCard {
                            Label("还没有长期记忆。Lamp 只会保存经过确认的信息。", systemImage: "brain.head.profile")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(store.memories) { memory in
                            memoryCard(memory)
                        }
                    }
                    SectionLabel(title: "规划规则")
                    ForEach(store.rules) { rule in
                        Toggle(isOn: Binding(
                            get: { store.rules.first(where: { $0.id == rule.id })?.isEnabled ?? false },
                            set: { store.toggleRule(id: rule.id, isEnabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(rule.title).font(.body.weight(.semibold))
                                    if rule.isHard {
                                        Text("硬规则")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.red)
                                            .padding(.horizontal, 6).padding(.vertical, 3)
                                            .background(.red.opacity(0.1), in: Capsule())
                                    }
                                }
                                Text(rule.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tint(LampTheme.sage)
                        .padding(16)
                        .background(LampTheme.secondaryBackground.opacity(0.82), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                        .accessibilityIdentifier("memory.rule.\(rule.id.uuidString)")
                    }
                    Button(action: showPrivacy) {
                        Label("隐私、导出与删除", systemImage: "hand.raised.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.lamp)
                    .accessibilityIdentifier("memory.privacy")
                }
                .padding(.horizontal, LampTheme.Spacing.page)
                .padding(.top, 20)
                .padding(.bottom, 44)
            }
            .scrollIndicators(.hidden)
            .navigationBarHidden(true)
            .lampPage()
            .sheet(item: $editingMemory) { MemoryEditorView(memory: $0) }
            .confirmationDialog(
                "删除这条记忆？",
                isPresented: Binding(
                    get: { deletingMemory != nil },
                    set: { if !$0 { deletingMemory = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除记忆", role: .destructive) {
                    if let memory = deletingMemory { store.deleteMemory(memory) }
                    deletingMemory = nil
                }
                Button("取消", role: .cancel) { deletingMemory = nil }
            } message: {
                Text("删除后可以通过顶部提示立即撤销。")
            }
        }
    }

    private func summary(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.headline)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(LampTheme.secondaryBackground.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func memoryCard(_ memory: MemoryFact) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: memory.icon)
                .foregroundStyle(LampTheme.amber)
                .frame(width: 34, height: 34)
                .background(LampTheme.amber.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(memory.title).font(.body.weight(.semibold))
                Text(memory.detail).font(.subheadline).foregroundStyle(.secondary)
                Text(memory.source).font(.caption2).foregroundStyle(LampTheme.muted)
            }
            Spacer()
            Menu {
                Button("编辑", systemImage: "pencil") { editingMemory = memory }
                Button("删除", systemImage: "trash", role: .destructive) { deletingMemory = memory }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("管理记忆：\(memory.title)")
            .accessibilityIdentifier("memory.menu.\(memory.id.uuidString)")
        }
        .padding(16)
        .background(LampTheme.secondaryBackground.opacity(0.82), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
    }
}

struct MemoryEditorView: View {
    @EnvironmentObject private var store: LampStore
    @Environment(\.dismiss) private var dismiss
    let memory: MemoryFact
    @State private var title: String
    @State private var detail: String

    init(memory: MemoryFact) {
        self.memory = memory
        _title = State(initialValue: memory.title)
        _detail = State(initialValue: memory.detail)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Lamp 应该记住") {
                    TextField("标题", text: $title)
                        .accessibilityIdentifier("memoryEditor.title")
                    TextField("说明", text: $detail, axis: .vertical)
                        .lineLimit(3...7)
                        .accessibilityIdentifier("memoryEditor.detail")
                }
                Section {
                    Text("由你编辑的内容会成为已确认记忆。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("编辑记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.updateMemory(memory, title: title, detail: detail)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("memoryEditor.save")
                }
            }
        }
    }
}

struct PrivacyDataView: View {
    @EnvironmentObject private var store: LampStore
    @Environment(\.dismiss) private var dismiss
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var showingClearConfirmation = false
    @State private var showingDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section("你的控制") {
                    Button {
                        do {
                            exportURL = try store.exportData()
                            exportError = nil
                        } catch {
                            exportError = "导出失败：\(error.localizedDescription)"
                        }
                    } label: {
                        Label("准备全部 Lamp 数据", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("privacy.export")

                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("分享导出文件", systemImage: "paperplane.fill")
                        }
                        .accessibilityIdentifier("privacy.shareExport")
                    }

                    Button {
                        showingClearConfirmation = true
                    } label: {
                        Label("清除本机缓存", systemImage: "externaldrive.badge.minus")
                    }
                    .accessibilityIdentifier("privacy.clearCache")

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("删除本机 Lamp 数据", systemImage: "trash")
                    }
                    .accessibilityIdentifier("privacy.deleteLocal")
                }

                if let exportError {
                    Section { Text(exportError).foregroundStyle(.red) }
                }

                Section("数据源") {
                    NavigationLink {
                        DataSourceDetailView(source: .calendar)
                    } label: {
                        LabeledContent("日历", value: "可选连接")
                    }
                    NavigationLink {
                        DataSourceDetailView(source: .health)
                    } label: {
                        LabeledContent("健康", value: "尚未启用")
                    }
                    NavigationLink {
                        DataSourceDetailView(source: .photos)
                    } label: {
                        LabeledContent("照片", value: "按次授权")
                    }
                }

                Section {
                    Label("Supabase 云同步尚未启用，因此这里不会显示虚假的云端删除入口。", systemImage: "icloud.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("隐私与数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .confirmationDialog("清除缓存？", isPresented: $showingClearConfirmation, titleVisibility: .visible) {
                Button("清除缓存", role: .destructive) { _ = store.clearCaches() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("计划、记忆和设置不会被删除。")
            }
            .alert("删除本机全部数据？", isPresented: $showingDeleteConfirmation) {
                Button("永久删除", role: .destructive) {
                    dismiss()
                    store.deleteAllLocalData()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会删除本机计划、记忆、规则和引导设置，且无法撤销。")
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private enum LampDataSource: Equatable {
    case calendar
    case health
    case photos

    var title: String {
        switch self {
        case .calendar: "系统日历"
        case .health: "健康数据"
        case .photos: "照片"
        }
    }

    var icon: String {
        switch self {
        case .calendar: "calendar"
        case .health: "heart.fill"
        case .photos: "photo.on.rectangle"
        }
    }
}

private struct DataSourceDetailView: View {
    let source: LampDataSource
    @State private var status: String?

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: source.icon)
                        .font(.system(size: 34))
                        .foregroundStyle(LampTheme.amber)
                    Text(source.title).font(.title2.bold())
                    Text(explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
            Section {
                if source == .calendar {
                    Button("请求日历访问") {
                        Task {
                            do {
                                let granted = try await EKEventStore().requestFullAccessToEvents()
                                status = granted ? "已获得日历访问权限" : "未授权；可稍后在系统设置中更改"
                            } catch {
                                status = "无法请求权限：\(error.localizedDescription)"
                            }
                        }
                    }
                }
                Button("打开系统设置") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
            if let status { Section { Text(status) } }
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var explanation: String {
        switch source {
        case .calendar:
            "授权后 Lamp 可以读取固定日程并避开冲突。当前版本不会自动写入系统日历。"
        case .health:
            "健康数据连接将在完成 HealthKit 能力配置后开放。当前规划不会假装使用未连接的数据。"
        case .photos:
            "Lamp 只在你主动选择图片时读取该图片，不会浏览整个照片图库。"
        }
    }
}

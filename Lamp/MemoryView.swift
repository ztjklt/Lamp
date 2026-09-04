import SwiftUI

struct MemoryView: View {
    @EnvironmentObject private var store: LampStore
    @State private var showingPrivacy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lamp 了解的你").font(.largeTitle.bold())
                        Text("所有长期记忆都由你掌控。").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        summary("\(store.memories.count)", "条记忆")
                        summary("\(store.rules.filter(\.isEnabled).count)", "条规则")
                        summary("本地", "当前数据")
                    }
                    SectionLabel(title: "记忆")
                    ForEach(store.memories) { memory in
                        memoryCard(memory)
                    }
                    SectionLabel(title: "规划规则")
                    ForEach(store.rules) { rule in
                        Toggle(isOn: Binding(
                            get: { rule.isEnabled },
                            set: { _ in store.toggleRule(rule) }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(rule.title).font(.body.weight(.semibold))
                                    if rule.isHard { Text("硬规则").font(.caption2.weight(.semibold)).foregroundStyle(.red).padding(.horizontal, 6).padding(.vertical, 3).background(.red.opacity(0.08), in: Capsule()) }
                                }
                                Text(rule.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tint(LampTheme.sage).padding(16).background(.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 19))
                    }
                    Button { showingPrivacy = true } label: {
                        Label("隐私、导出与删除", systemImage: "hand.raised.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(LampTheme.ink).controlSize(.large)
                }
                .padding(.horizontal, 20).padding(.top, 20)
            }
            .scrollIndicators(.hidden)
            .sheet(isPresented: $showingPrivacy) { privacySheet }
        }
    }

    private func summary(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.headline)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 14).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
    }

    private func memoryCard(_ memory: MemoryFact) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: memory.icon).foregroundStyle(LampTheme.amber).frame(width: 30, height: 30).background(LampTheme.amber.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(memory.title).font(.body.weight(.semibold))
                Text(memory.detail).font(.subheadline).foregroundStyle(.secondary)
                Text(memory.source).font(.caption2).foregroundStyle(LampTheme.muted)
            }
            Spacer()
            Menu {
                Button("编辑", systemImage: "pencil") { }
                Button("删除", systemImage: "trash", role: .destructive) { store.deleteMemory(memory) }
            } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).padding(4) }
        }
        .padding(16).background(.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 19))
    }

    private var privacySheet: some View {
        NavigationStack {
            List {
                Section("你的控制") {
                    Label("导出全部 Lamp 数据", systemImage: "square.and.arrow.up")
                    Label("清除本机缓存", systemImage: "externaldrive.badge.minus")
                    Label("删除账户与云端数据", systemImage: "trash").foregroundStyle(.red)
                }
                Section("数据源") {
                    LabeledContent("日历", value: "未连接")
                    LabeledContent("健康", value: "未连接")
                    LabeledContent("照片", value: "按次授权")
                }
            }
            .navigationTitle("隐私与数据").navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}


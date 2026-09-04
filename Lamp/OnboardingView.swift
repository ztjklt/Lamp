import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var store: LampStore
    @State private var page = 0
    @State private var context = "学生"
    @State private var wakeTime = Date.now
    @State private var sleepTime = Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: .now)!

    var body: some View {
        ZStack {
            LampTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    LampLight(size: 30)
                    Spacer()
                    Text("\(page + 1) / 3").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24).padding(.top, 12)

                TabView(selection: $page) {
                    welcome.tag(0)
                    essentials.tag(1)
                    ready.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 12) {
                    if page > 0 {
                        Button("返回") { withAnimation { page -= 1 } }
                            .buttonStyle(.bordered).tint(LampTheme.ink)
                    }
                    Button(page == 2 ? "看看今天" : "继续") {
                        if page == 2 { store.finishOnboarding() } else { withAnimation { page += 1 } }
                    }
                    .buttonStyle(.borderedProminent).tint(LampTheme.ink)
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large).padding(24)
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            Text("少想一点，\n更清楚地行动。")
                .font(.system(size: 42, weight: .semibold, design: .rounded))
                .foregroundStyle(LampTheme.ink)
            Text("告诉 Lamp 你想完成什么、现实中发生了什么。它会替你守住结构，并在每个时刻给出一个清楚的下一步。")
                .font(.title3).foregroundStyle(LampTheme.muted).lineSpacing(6)
            LampCard {
                HStack(spacing: 14) {
                    Image(systemName: "quote.opening").foregroundStyle(LampTheme.amber)
                    Text("我想学 AI、金融和微积分，但不知道怎么安排。")
                        .font(.body.weight(.medium))
                }
            }
            Spacer()
        }
        .padding(28)
    }

    private var essentials: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            Text("先了解最必要的部分")
                .font(.largeTitle.bold()).foregroundStyle(LampTheme.ink)
            Text("其余的，Lamp 会在使用中慢慢学习。")
                .font(.title3).foregroundStyle(.secondary)

            LampCard {
                VStack(alignment: .leading, spacing: 18) {
                    Text("你现在的主要状态").font(.subheadline.weight(.semibold))
                    Picker("主要状态", selection: $context) {
                        Text("学生").tag("学生")
                        Text("工作").tag("工作")
                        Text("其他").tag("其他")
                    }.pickerStyle(.segmented)
                    Divider()
                    DatePicker("通常起床", selection: $wakeTime, displayedComponents: .hourAndMinute)
                    DatePicker("通常休息", selection: $sleepTime, displayedComponents: .hourAndMinute)
                }
            }
            Text("日历、照片、麦克风等权限只会在你使用相关功能时询问。")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(28)
    }

    private var ready: some View {
        VStack(spacing: 24) {
            Spacer()
            LampLight(size: 84)
            Text("第一份计划准备好了")
                .font(.largeTitle.bold()).foregroundStyle(LampTheme.ink)
            Text("今天先从两个重点开始。你可以随时移动、完成，或直接告诉 Lamp 现实发生了变化。")
                .font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(5)
            HStack(spacing: 14) {
                stat("2", "重点")
                stat("3h", "专注")
                stat("90m", "留白")
            }
            Spacer()
        }
        .padding(28)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 5) {
            Text(value).font(.title2.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
    }
}


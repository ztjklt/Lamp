import SwiftUI

enum LampTheme {
    static let background = Color(red: 0.97, green: 0.96, blue: 0.93)
    static let card = Color.white.opacity(0.9)
    static let ink = Color(red: 0.13, green: 0.14, blue: 0.13)
    static let muted = Color(red: 0.43, green: 0.43, blue: 0.39)
    static let amber = Color(red: 0.96, green: 0.56, blue: 0.16)
    static let amberSoft = Color(red: 1.0, green: 0.86, blue: 0.58)
    static let sage = Color(red: 0.40, green: 0.55, blue: 0.43)
}

struct LampLight: View {
    var size: CGFloat = 44
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(LampTheme.amber.opacity(0.14))
                .frame(width: size * 1.55, height: size * 1.55)
                .blur(radius: 10)
                .scaleEffect(breathing ? 1.08 : 0.92)
            Circle()
                .fill(
                    RadialGradient(colors: [.white, LampTheme.amberSoft, LampTheme.amber], center: .topLeading, startRadius: 2, endRadius: size)
                )
                .frame(width: size, height: size)
                .shadow(color: LampTheme.amber.opacity(0.28), radius: 12, y: 4)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathing = true }
        }
        .accessibilityLabel("Lamp 状态：已准备好")
    }
}

struct LampCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .background(LampTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.8), lineWidth: 1))
            .shadow(color: .black.opacity(0.045), radius: 18, y: 8)
    }
}

struct SectionLabel: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(LampTheme.muted)
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
        }
    }
}


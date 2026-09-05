import SwiftUI
import UIKit

enum LampTheme {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let secondaryBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let controlBackground = Color(uiColor: .tertiarySystemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let ink = Color.primary
    static let muted = Color.secondary
    static let amberUIColor = UIColor(red: 0.96, green: 0.53, blue: 0.12, alpha: 1)
    static let amber = Color(uiColor: amberUIColor)
    static let amberSoft = Color(red: 1.0, green: 0.77, blue: 0.34)
    static let sage = Color(red: 0.32, green: 0.58, blue: 0.39)
    static let danger = Color(uiColor: .systemRed)
    static let hairline = Color(uiColor: .separator).opacity(0.38)
    static let primaryAction = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.96, green: 0.53, blue: 0.12, alpha: 1)
            : UIColor.label
    })
    static let onPrimaryAction = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.black : UIColor.white
    })

    enum Spacing {
        static let page: CGFloat = 20
        static let section: CGFloat = 24
        static let card: CGFloat = 18
        static let control: CGFloat = 12
    }

    enum Radius {
        static let card: CGFloat = 24
        static let control: CGFloat = 16
        static let floating: CGFloat = 28
    }
}

enum LampGlassSurfaceStyle {
    case regular
    case prominent
    case subtle
}

struct LampBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LampTheme.background
            LinearGradient(
                colors: [
                    LampTheme.amber.opacity(colorScheme == .dark ? 0.10 : 0.08),
                    .clear,
                    LampTheme.sage.opacity(colorScheme == .dark ? 0.06 : 0.035)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

private struct LampGlassSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let style: LampGlassSurfaceStyle
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(LampTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(LampTheme.hairline, lineWidth: 1)
                }
        } else if #available(iOS 26.0, *) {
            switch style {
            case .prominent:
                content.glassEffect(
                    .regular.tint(LampTheme.amber.opacity(0.28)).interactive(),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            case .regular:
                content.glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            case .subtle:
                content.glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            }
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.42), lineWidth: 0.8)
                }
        }
    }
}

extension View {
    func lampGlass(
        _ style: LampGlassSurfaceStyle = .regular,
        cornerRadius: CGFloat = LampTheme.Radius.floating
    ) -> some View {
        modifier(LampGlassSurfaceModifier(style: style, cornerRadius: cornerRadius))
    }

    func lampPage() -> some View {
        background(LampBackground()).tint(LampTheme.amber)
    }
}

struct LampLight: View {
    var size: CGFloat = 44
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(LampTheme.amber.opacity(0.16))
                .frame(width: size * 1.6, height: size * 1.6)
                .blur(radius: size * 0.25)
                .scaleEffect(!reduceMotion && breathing ? 1.08 : 0.94)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white, LampTheme.amberSoft, LampTheme.amber],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: size
                    )
                )
                .frame(width: size, height: size)
                .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 0.8))
                .shadow(color: LampTheme.amber.opacity(0.32), radius: 14, y: 5)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lamp 状态：已准备好")
    }
}

struct LampCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(LampTheme.Spacing.card)
            .background(LampTheme.card, in: RoundedRectangle(cornerRadius: LampTheme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LampTheme.Radius.card, style: .continuous)
                    .stroke(LampTheme.hairline, lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.055), radius: 18, y: 8)
    }
}

struct SectionLabel: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.3)
                .foregroundStyle(LampTheme.muted)
            Spacer()
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct LampActionButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? LampTheme.onPrimaryAction : LampTheme.ink)
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
            .background(
                prominent ? LampTheme.primaryAction.opacity(configuration.isPressed ? 0.78 : 1) : LampTheme.controlBackground.opacity(configuration.isPressed ? 0.65 : 0.96),
                in: Capsule()
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == LampActionButtonStyle {
    static var lamp: LampActionButtonStyle { LampActionButtonStyle(prominent: false) }
    static var lampProminent: LampActionButtonStyle { LampActionButtonStyle(prominent: true) }
}

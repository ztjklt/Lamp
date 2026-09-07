import SwiftUI
import UIKit

/// A lightweight frame animation used only for schedule blocks that are explicitly marked as sleep.
struct LampRestAnimation: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var frameIndex = 0
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    let size: CGFloat

    private static let images: [UIImage] = (1...7).map { index in
        UIImage(named: String(format: "LampRest%02d", index)) ?? UIImage()
    }
    private static let playbackSequence = [0, 1, 2, 3, 4, 5, 6, 6, 6, 5, 4, 3, 2, 1, 0]

    private var shouldAnimate: Bool {
        !reduceMotion
            && !lowPowerMode
            && scenePhase == .active
            && !ProcessInfo.processInfo.arguments.contains("-freeze-rest-animation")
    }

    var body: some View {
        Image(uiImage: Self.images[frameIndex])
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .task(id: shouldAnimate) {
                guard shouldAnimate else {
                    frameIndex = 6
                    return
                }

                while !Task.isCancelled {
                    for index in Self.playbackSequence {
                        guard !Task.isCancelled else { return }
                        frameIndex = index
                        try? await Task.sleep(nanoseconds: 280_000_000)
                    }
                }
            }
    }
}

enum LampSleepTheme {
    static let foreground = Color(red: 0.98, green: 0.96, blue: 0.88)
    static let secondary = Color(red: 0.80, green: 0.84, blue: 0.94)
    static let accent = Color(red: 0.98, green: 0.75, blue: 0.35)

    static var background: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.09, green: 0.12, blue: 0.23),
                Color(red: 0.16, green: 0.21, blue: 0.38),
                Color(red: 0.24, green: 0.25, blue: 0.43)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct LampSleepSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let highlighted: Bool

    func body(content: Content) -> some View {
        content
            .background(LampSleepTheme.background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        highlighted ? LampSleepTheme.accent : Color.white.opacity(0.16),
                        lineWidth: highlighted ? 2 : 0.8
                    )
            }
            .shadow(color: Color.indigo.opacity(0.22), radius: 18, y: 8)
    }
}

extension View {
    func lampSleepSurface(cornerRadius: CGFloat = LampTheme.Radius.card, highlighted: Bool = false) -> some View {
        modifier(LampSleepSurfaceModifier(cornerRadius: cornerRadius, highlighted: highlighted))
    }
}

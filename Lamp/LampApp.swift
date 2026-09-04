import SwiftUI

@main
struct LampApp: App {
    @StateObject private var store = LampStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.light)
        }
    }
}


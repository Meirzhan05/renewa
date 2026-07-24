import SwiftUI

@main
struct RenewaApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.light)
                .task {
                    await store.bootstrap()
                }
        }
    }
}

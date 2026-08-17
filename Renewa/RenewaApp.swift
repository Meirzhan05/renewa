import SwiftUI

@main
struct RenewaApp: App {
    @State private var store = AppStore()
    @UIApplicationDelegateAdaptor(NotificationAppDelegate.self) private var notificationDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.light)
                .task {
                    await store.bootstrap()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await store.appDidBecomeActive()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .renewaDeviceTokenUpdated)) { notification in
                    guard let token = notification.object as? String else { return }
                    Task { await store.receivedAPNSDeviceToken(token) }
                }
        }
    }
}

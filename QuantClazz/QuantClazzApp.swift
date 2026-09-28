import SwiftUI

@main
struct QuantClazzApp: App {
    @StateObject private var session = AppSession()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ForumRootView()
                .environmentObject(session)
                .tint(ForumTheme.accent)
                .preferredColorScheme(.light)
                .sheet(isPresented: $session.showLogin) {
                    OfficialLoginView().environmentObject(session)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active, session.isLoggedIn { Task { await session.refreshCurrentUser(force: false) } }
                }
        }
    }
}

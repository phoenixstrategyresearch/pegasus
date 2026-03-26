import SwiftUI

struct ContentView: View {
    @EnvironmentObject var backend: BackendService
    @State private var selectedTab = 0
    @State private var showingSplash = true
    @State private var pendingShortcut: Notification?

    private let tabs: [(String, String)] = [
        ("Chat", "message.fill"),
        ("Models", "cpu"),
        ("Terminal", "terminal"),
        ("Files", "doc.fill"),
        ("Settings", "gear"),
    ]

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ZStack {
                    // Keep Chat always alive for message persistence
                    ChatView()
                        .opacity(selectedTab == 0 ? 1 : 0)
                        .allowsHitTesting(selectedTab == 0)

                    // Other tabs created on demand
                    if selectedTab == 1 { ModelsView() }
                    if selectedTab == 2 { TerminalView() }
                    if selectedTab == 3 { FilesView() }
                    if selectedTab == 4 { SettingsView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                LeopardTabBar(selectedTab: $selectedTab, tabs: tabs)
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .onReceive(NotificationCenter.default.publisher(for: .pegasusShortcutTriggered)) { notification in
                // Switch to chat tab when shortcut fires
                selectedTab = 0
            }

            // Splash screen
            if showingSplash {
                GeometryReader { geo in
                    ZStack {
                        Image("Background")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()

                        PegasusLogo(size: 180)
                    }
                }
                .ignoresSafeArea()
                .transition(.opacity)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        withAnimation(.easeOut(duration: 0.8)) {
                            showingSplash = false
                        }
                    }
                }
            }
        }
    }
}

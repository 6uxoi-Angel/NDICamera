import SwiftUI

@main
struct NDICameraApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .preferredColorScheme(.dark)
                .onAppear { appModel.setup() }
        }
    }
}

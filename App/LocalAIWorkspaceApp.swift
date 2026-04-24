import LocalAIWorkspace
import SwiftUI

@main
struct LocalAIWorkspaceApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}

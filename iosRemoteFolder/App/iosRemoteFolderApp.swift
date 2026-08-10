import SwiftUI
import SwiftData

@main
struct iosRemoteFolderApp: App {
    private let modelContainer: ModelContainer
    @State private var appModel: AppModel

    init() {
        do {
            let container = try SourceConfigurationPersistence.makePersistentContainer()
            self.modelContainer = container
            _appModel = State(initialValue: AppModel(modelContainer: container))
        } catch {
            fatalError("无法创建来源配置容器：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
        }
    }
}

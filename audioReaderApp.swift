import SwiftUI
import SwiftData

@main
struct audioReaderApp: App {
    @State private var ttsService = TTSService()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Book.self])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(ttsService)
                .task {
                    // Pre-load TTS models in background on app launch
                    await ttsService.initialize()
                }
        }
        .modelContainer(sharedModelContainer)
    }
}

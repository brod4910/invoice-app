import SwiftUI
import SwiftData

@main
struct InvoiceApp: App {
    let container: ModelContainer
    @State private var processor: JobProcessor
    @State private var gmail = GmailClient()

    init() {
        let container = try! ModelContainer(for: Client.self, Job.self, Recording.self, LineItem.self, Invoice.self)
        self.container = container
        _processor = State(initialValue: JobProcessor(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(processor)
                .environment(gmail)
                .dynamicTypeSize(.large ... .accessibility3)
                .task {
                    await gmail.restore()
                    processor.removeEmptyJobs()
                    await processor.retryPending()
                }
        }
        .modelContainer(container)
    }
}

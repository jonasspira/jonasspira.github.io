import AppKit
import OpenPopsCore

@main
enum OpenPopsMain {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        let app = NSApplication.shared

        if let i = args.firstIndex(of: "--self-test") {
            let out = args.count > i + 1 ? args[i + 1] : "build/self-test"
            SelfTest.run(outputDirectory: URL(fileURLWithPath: out))
        }

        let model = AppModel(store: LibraryStore())
        let delegate = AppDelegate(model: model)
        app.delegate = delegate
        // `delegate` stays alive for as long as run() does.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

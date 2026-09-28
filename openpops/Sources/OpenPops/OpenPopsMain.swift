import AppKit
import OpenPopsCore

// Temporary entry point used to check the CI pipeline; replaced by the real app.
@main
enum OpenPopsMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let library = LibraryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("openpops-ci-probe")).library
        print("OpenPops probe: \(library.pops.count) pops, \(BuiltInThemes.all.count) themes")
        if CommandLine.arguments.contains("--probe") { return }
        app.setActivationPolicy(.regular)
        app.run()
    }
}

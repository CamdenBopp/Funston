import SwiftUI
import UIKit

@MainActor
enum SettingsPresentation {
    static func present(from presenter: UIViewController, environment: AppEnvironment) {
        let controller = UIHostingController(rootView: SettingsView(environment: environment, settings: environment.settings))
        controller.modalPresentationStyle = .fullScreen
        presenter.present(controller, animated: true)
    }
}

private struct SettingsView: View {
    let environment: AppEnvironment
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemoval = false
    @State private var working = false
    @State private var status: String?
    @ObservedObject private var downloads: DownloadManager

    init(environment: AppEnvironment, settings: SettingsStore) {
        self.environment = environment; self.settings = settings
        downloads = environment.downloads
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    Picker("Default speed", selection: $settings.defaultPlaybackSpeed) {
                        ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3], id: \.self) { speed in
                            Text("\(speed.formatted())×").tag(speed)
                        }
                        if ![0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3].contains(settings.defaultPlaybackSpeed) {
                            Text("\(settings.defaultPlaybackSpeed.formatted())×").tag(settings.defaultPlaybackSpeed)
                        }
                    }
                    intervalPicker("Skip back", selection: $settings.skipBackSeconds)
                    intervalPicker("Skip forward", selection: $settings.skipForwardSeconds)
                    Toggle("Auto-play next", isOn: $settings.autoPlayNext)
                    Picker("Sleep timer default", selection: $settings.sleepTimerMinutes) {
                        Text("Off").tag(0)
                        ForEach([15, 30, 45, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                        Text("End of recording").tag(-1)
                    }
                }
                Section("Downloads") {
                    Toggle("Allow cellular", isOn: $settings.allowCellularDownloads)
                    Toggle("Auto-delete after played", isOn: $settings.autoDeletePlayedDownloads)
                    LabeledContent("Storage used", value: ByteCountFormatter.string(fromByteCount: downloads.storageUsedBytes, countStyle: .file))
                    Button("Remove All Downloads", role: .destructive) { confirmRemoval = true }
                        .disabled(working)
                    Button("Clear Cache") { clearCache() }.disabled(working)
                }
                Section("Reading") {
                    Picker("Default text recognition", selection: $settings.textRecognitionEngine) {
                        ForEach(PDFTextEnginePreference().options(ocrEngines: PDFPageTextEngineRegistry.builtIn.descriptors).filter(\.isAvailable), id: \.id) { engine in
                            Text(engine.title).tag(engine.id)
                        }
                    }
                    Picker("Default reading layout", selection: $settings.readingLayout) {
                        ForEach(PDFReadingLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section("Content") {
                    Toggle("Hide items without playable or readable media", isOn: $settings.hideUnsupportedMedia)
                }
                Section("About") {
                    LabeledContent("Version", value: version)
                    Link("Internet Archive", destination: URL(string: "https://archive.org")!)
                    NavigationLink("Acknowledgments") {
                        SettingsTextPage(title: "Acknowledgments", text: notices)
                    }
                    NavigationLink("Privacy policy") {
                        SettingsTextPage(title: "Privacy policy", text: "Funston stores your library, downloads, settings, and listening and reading positions on your device. Funston requests media, artwork, and catalog information from Internet Archive. Those requests include your IP address and the Funston app version. Funston does not include analytics or advertising tracking. Internet Archive’s privacy policy applies to its service.", linkTitle: "Internet Archive privacy policy", linkURL: URL(string: "https://archive.org/about/terms.php"))
                    }
                    if let repository = BugReport.repository {
                        Link("View on GitHub", destination: repository)
                    }
                    if let bugReport = bugReport.url {
                        Link("Report a bug", destination: bugReport)
                    }
                    NavigationLink("Shortcuts help") {
                        Form {
                            Section("Say to Siri") {
                                Text("Resume listening in Funston")
                                Text("Pause Funston")
                                Text("Set a sleep timer in Funston")
                                Text("Stop at the end of the recording in Funston")
                                Text("Play [saved audio item] in Funston")
                            }
                            Section("In the Shortcuts app") {
                                Text("Add Funston actions to skip, change playback speed, move between recordings, cancel a sleep timer, save the current item, or get its title.")
                            }
                        }.navigationTitle("Shortcuts help")
                    }
                }
                if let status { Section { Text(status) } }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Remove all downloads?", isPresented: $confirmRemoval) {
                Button("Remove All Downloads", role: .destructive) { removeDownloads() }
                Button("Cancel", role: .cancel) { }
            } message: { Text("This cancels active transfers and removes downloaded files. Items saved to your Library remain saved.") }
            .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChange)) { _ in settings.objectWillChange.send() }
        }
    }

    private func intervalPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { Text("\($0) seconds").tag($0) }
        }
    }
    private var version: String {
        let bundle = Bundle.main
        return "\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))"
    }
    private var bugReport: BugReport {
        let bundle = Bundle.main
        let device = UIDevice.current
        let category = UIApplication.shared.preferredContentSizeCategory.rawValue
        return BugReport(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            systemVersion: device.systemVersion,
            model: Self.modelIdentifier,
            voiceOverRunning: UIAccessibility.isVoiceOverRunning,
            textSize: category.replacingOccurrences(of: "UICTContentSizeCategory", with: "")
        )
    }
    /// The hardware identifier, such as "iPhone17,1". UIDevice.model only says "iPhone".
    private static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return "\(simulated) simulator" }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    private var notices: String {
        Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Acknowledgments are unavailable."
    }
    private func report(_ text: String) {
        status = text
        UIAccessibility.post(notification: .announcement, argument: text)
    }
    private func removeDownloads() {
        working = true
        Task {
            do { try await downloads.removeAllDownloads(); report("All downloads removed.") }
            catch { report("Could not remove all downloads. \(error.localizedDescription)") }
            working = false
        }
    }
    private func clearCache() {
        working = true
        Task {
            do {
                try await environment.store.clearCache()
                ArchiveNetworkPolicy.cache.removeAllCachedResponses()
                await ArtworkPipeline.shared.clearCache()
                report("Cache cleared.")
            } catch { report("Could not clear cache. \(error.localizedDescription)") }
            working = false
        }
    }
}

private struct SettingsTextPage: View {
    let title: String
    let text: String
    var linkTitle: String? = nil
    var linkURL: URL? = nil
    var body: some View {
        Form {
            Text(text)
            if let linkTitle, let linkURL { Link(linkTitle, destination: linkURL) }
        }
            .navigationTitle(title)
    }
}

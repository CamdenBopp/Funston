import UIKit
import Combine
import AppIntents
import CarPlay

actor LibraryPersistence {
    let store: SQLiteStore
    init(store: SQLiteStore) { self.store = store }
    func all() async throws -> [ArtifactSummary] {
        try await store.savedArtifacts().compactMap { try? JSONDecoder().decode(ArtifactSummary.self, from: $0) }.filter { !$0.isAccessRestricted }
    }
    func save(_ artifact: ArtifactSummary) async throws {
        try await store.saveArtifact(identifier: artifact.identifier, snapshot: JSONEncoder().encode(artifact))
    }
    func remove(_ artifact: ArtifactSummary) async throws {
        try await store.removeSavedArtifact(identifier: artifact.identifier)
    }
}

@MainActor
final class AppEnvironment: ObservableObject {
    let store: SQLiteStore
    let repository: CachingArchiveRepository
    let downloads: DownloadManager
    let playback: PlaybackController
    let settings: SettingsStore
    private var librarySubscriptions = Set<AnyCancellable>()
    private let library: LibraryPersistence
    @Published private(set) var saved: [ArtifactSummary] = []
    @Published private(set) var libraryError: String?

    /// Tests pass an ephemeral session so they never touch the app's background transfers.
    init(store: SQLiteStore, mediaDirectory: URL, downloadSession: URLSessionConfiguration? = nil, settings: SettingsStore = .shared) {
        self.store = store
        self.settings = settings
        repository = CachingArchiveRepository(store: store, settings: settings)
        downloads = DownloadManager(store: store, mediaDirectory: mediaDirectory, sessionConfiguration: downloadSession, settings: settings)
        let playbackRepository = repository
        playback = PlaybackController(store: store, downloads: downloads, settings: settings,
            artifactDetailLoader: { identifier in try await playbackRepository.detail(identifier: identifier) })
        library = LibraryPersistence(store: store)
        downloads.$records.map { Set($0.map(\.identifier)) }.removeDuplicates()
            .dropFirst().sink { [weak self] _ in Task { await self?.reloadLibrary() } }
            .store(in: &librarySubscriptions)
    }

    static func make() async throws -> AppEnvironment {
        let resources = try await Task.detached(priority: .userInitiated) {
            let store = try SQLiteStore(url: AppPaths.database())
            let mediaDirectory = try AppPaths.media()
            return (store, mediaDirectory)
        }.value
        return AppEnvironment(store: resources.0, mediaDirectory: resources.1)
    }

    func start() async {
        await reloadLibrary()
        #if DEBUG
        // Exercise first playback without deleting the user's saved library or
        // listening bookmark. This switch is unavailable in release builds.
        if ProcessInfo.processInfo.arguments.contains("--skip-playback-restoration") { return }
        // Unit tests run inside this app. Restoring whatever was last played on the
        // simulator would publish its Now Playing over the test's own.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        #endif
        await restorePlaybackIfNeeded()
    }

    /// Shared by scene startup and background Shortcuts without starting playback.
    func restorePlaybackIfNeeded() async {
        guard let bookmark = try? await store.lastPlayback(), playback.context == nil else { return }
        let restoreGeneration = playback.loadGeneration
        if let localRecord = await downloads.completedRecord(
            identifier: bookmark.identifier,
            fileName: bookmark.fileName
        ) {
            guard playback.context == nil, playback.loadGeneration == restoreGeneration else { return }
            playback.playDownloaded(localRecord, autoplay: false)
            return
        }
        guard let detail = try? await repository.detail(identifier: bookmark.identifier),
              let index = detail.tracks.firstIndex(where: { $0.candidates.contains(where: { $0.name == bookmark.fileName }) }),
              playback.context == nil,
              playback.loadGeneration == restoreGeneration else { return }
        playback.load(artifact: detail.summary, tracks: detail.tracks, trackIndex: index, autoplay: false)
    }

    func reloadLibrary() async {
        do { saved = try await library.all(); libraryError = nil }
        catch { libraryError = error.localizedDescription }
    }

    func isSaved(_ artifact: ArtifactSummary) -> Bool { saved.contains { $0.identifier == artifact.identifier } }

    func setSaved(_ artifact: ArtifactSummary, saved shouldSave: Bool) async throws {
        if shouldSave { try await library.save(artifact) } else { try await library.remove(artifact) }
        saved = try await library.all()
        libraryError = nil
        FunstonShortcuts.updateAppShortcutParameters()
    }
}

@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var environment: AppEnvironment?
    var launchError: Error?
    var pendingBackgroundCompletionHandler: (() -> Void)?
    private var environmentTask: Task<AppEnvironment, Error>?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Background URLSession relaunches do not necessarily create a scene. Start the
        // app-scoped services from the application lifecycle so the session is recreated.
        FunstonShortcuts.updateAppShortcutParameters()
        Task { _ = try? await prepareEnvironment() }
        return true
    }

    func prepareEnvironment() async throws -> AppEnvironment {
        if let environment { return environment }
        if let environmentTask { return try await environmentTask.value }
        let task = Task { try await AppEnvironment.make() }
        environmentTask = task
        do {
            let environment = try await task.value
            self.environment = environment
            environmentTask = nil
            launchError = nil
            if let completion = pendingBackgroundCompletionHandler {
                pendingBackgroundCompletionHandler = nil
                environment.downloads.setBackgroundCompletionHandler(completion)
            }
            return environment
        } catch {
            environmentTask = nil
            launchError = error
            throw error
        }
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            return Self.carPlayConfiguration()
        }
        let configuration = UISceneConfiguration(name: "Funston", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    static func carPlayConfiguration() -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "CarPlay", sessionRole: .carTemplateApplication)
        configuration.sceneClass = CPTemplateApplicationScene.self
        configuration.delegateClass = CarPlaySceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if let environment {
            environment.downloads.setBackgroundCompletionHandler(completionHandler)
        } else {
            pendingBackgroundCompletionHandler = completionHandler
            Task {
                do {
                    _ = try await prepareEnvironment()
                } catch {
                    pendingBackgroundCompletionHandler = nil
                    completionHandler()
                }
            }
        }
    }
}

@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let delegate = UIApplication.shared.delegate as? AppDelegate else { return }
        Task {
            let environment = try? await delegate.prepareEnvironment()
            await environment?.downloads.refreshAvailability()
        }
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene, let delegate = UIApplication.shared.delegate as? AppDelegate else { return }
        let window = UIWindow(windowScene: scene)
        #if DEBUG
        switch ProcessInfo.processInfo.environment["FUNSTON_TEST_APPEARANCE"] {
        case "Light": window.overrideUserInterfaceStyle = .light
        case "Dark": window.overrideUserInterfaceStyle = .dark
        default: break
        }
        #endif
        let loadingController = UIViewController()
        loadingController.view.backgroundColor = .systemBackground
        var loading = UIContentUnavailableConfiguration.loading()
        loading.text = "Opening Funston"
        loadingController.contentUnavailableConfiguration = loading
        window.rootViewController = loadingController
        self.window = window
        window.makeKeyAndVisible()

        Task {
            do {
                let environment = try await delegate.prepareEnvironment()
                window.rootViewController = FunstonRootController(environment: environment)
                await environment.start()
            } catch {
                delegate.launchError = error
                var unavailable = UIContentUnavailableConfiguration.empty()
                unavailable.text = "Library unavailable"
                unavailable.secondaryText = error.localizedDescription
                loadingController.contentUnavailableConfiguration = unavailable
            }
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        (UIApplication.shared.delegate as? AppDelegate)?.environment?.playback.appDidEnterBackground()
    }
}

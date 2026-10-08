import UIKit
import SwiftUI
import Combine

@MainActor
final class FunstonRootController: UIViewController {
    private let environment: AppEnvironment
    private let tabs = UITabBarController()
    private var split: UISplitViewController?
    private var destinations: [UINavigationController] = []
    private var histories: [DestinationNavigationHistory] = []
    private var selectedDestination = 0
    private lazy var playerPresentation = FunstonPlayerPresentation(environment: environment)
    private var subscriptions = Set<AnyCancellable>()
    private var embedded: UIViewController?

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let explore = ExploreController(environment: environment, openCollection: { [weak self] collection in self?.openCollection(collection, destination: 0) }, openArtifact: { [weak self] artifact in self?.open(artifact, destination: 0) })
        let search = SearchController(environment: environment) { [weak self] artifact in self?.open(artifact, destination: 1) }
        let library = LibraryController(environment: environment) { [weak self] artifact in self?.open(artifact, destination: 2) }
        let downloads = DownloadsController(environment: environment) { [weak self] artifact in self?.open(artifact, destination: 3) }
        let symbols = ["safari", "magnifyingglass", "books.vertical", "arrow.down.circle"]
        destinations = [explore, search, library, downloads].enumerated().map { index, controller in
            let navigation = UINavigationController(rootViewController: controller)
            navigation.navigationBar.prefersLargeTitles = true
            navigation.tabBarItem = UITabBarItem(title: controller.title, image: UIImage(systemName: symbols[index]), tag: index)
            return navigation
        }
        histories = destinations.map(DestinationNavigationHistory.init)
        configureLayout()
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (controller: FunstonRootController, _: UITraitCollection) in
            controller.configureLayout()
        }
        environment.playback.$context.combineLatest(environment.playback.$phase, environment.playback.$wantsToPlay)
            // @Published delivers before the stored property is committed. Defer
            // constructing FullPlayer until it can seed and subscribe to committed
            // playback state, including the first nil-to-recording transition.
            .receive(on: RunLoop.main)
            .sink { [weak self] context, phase, wantsToPlay in
            self?.playerPresentation.update(context: context, phase: phase, wantsToPlay: wantsToPlay)
        }.store(in: &subscriptions)
    }

    func setReaderControlsHidden(_ hidden: Bool) {
        tabs.setTabBarHidden(hidden, animated: !UIAccessibility.isReduceMotionEnabled)
        playerPresentation.setReaderControlsHidden(hidden)
    }

    private func configureLayout() {
        let expanded = traitCollection.userInterfaceIdiom == .pad && traitCollection.horizontalSizeClass == .regular
        guard embedded == nil || expanded != (split != nil) else { return }
        playerPresentation.detach()
        if let old = embedded {
            old.willMove(toParent: nil); old.view.removeFromSuperview(); old.removeFromParent()
        }
        if expanded {
            if histories.indices.contains(tabs.selectedIndex) { selectedDestination = tabs.selectedIndex }
            tabs.setViewControllers([], animated: false)
            histories.forEach { $0.expandDetail() }
            let split = UISplitViewController(style: .tripleColumn)
            self.split = split
            // Three columns are useful only when the content and detail retain
            // readable widths. UIKit otherwise overlays the sidebar at launch.
            split.minimumPrimaryColumnWidth = 240
            split.maximumPrimaryColumnWidth = 320
            split.preferredPrimaryColumnWidth = 280
            split.minimumSupplementaryColumnWidth = 320
            split.preferredSupplementaryColumnWidth = 320
            updateSplitDisplayMode()
            let sidebar = DestinationController(selectedIndex: selectedDestination) { [weak self] index in self?.choose(index) }
            split.setViewController(UINavigationController(rootViewController: sidebar), for: .primary)
            split.setViewController(destinations[selectedDestination], for: .supplementary)
            split.setViewController(histories[selectedDestination].detail ?? emptyDetail(), for: .secondary)
            install(split)
        } else {
            if let split {
                split.setViewController(nil, for: .secondary)
                split.setViewController(nil, for: .supplementary)
                histories.forEach { $0.collapseDetail() }
                self.split = nil
            }
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = .systemBackground
            tabs.tabBar.backgroundColor = .systemBackground
            tabs.tabBar.isTranslucent = false
            tabs.tabBar.standardAppearance = appearance
            tabs.tabBar.scrollEdgeAppearance = appearance
            tabs.setViewControllers(destinations, animated: false)
            tabs.selectedIndex = selectedDestination
            install(tabs)
        }
        if let embedded { playerPresentation.attach(to: embedded) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSplitDisplayMode()
    }

    private func updateSplitDisplayMode() {
        guard let split else { return }
        let availableWidth = view.bounds.inset(by: view.safeAreaInsets).width
        // These are content budgets, not device/orientation checks: 280 for
        // destinations, 320 for results, and 400 for a readable artifact detail.
        let threeColumnWidth: CGFloat = 280 + 320 + 400
        let mode: UISplitViewController.DisplayMode = availableWidth >= threeColumnWidth ? .twoBesideSecondary : .oneBesideSecondary
        guard split.preferredDisplayMode != mode else { return }
        split.preferredDisplayMode = mode
        if mode == .oneBesideSecondary, split.parent != nil { split.hide(.primary) }
    }

    private func install(_ child: UIViewController) {
        embedded = child
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor), child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        child.didMove(toParent: self)
    }

    private func emptyDetail() -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.text = "No item selected"
        controller.contentUnavailableConfiguration = configuration
        return controller
    }

    private func choose(_ index: Int) {
        guard histories.indices.contains(index) else { return }
        selectedDestination = index
        split?.setViewController(destinations[index], for: .supplementary)
        split?.setViewController(histories[index].detail ?? emptyDetail(), for: .secondary)
        split?.show(.supplementary)
        if split?.preferredDisplayMode == .oneBesideSecondary { split?.hide(.primary) }
    }

    private func openCollection(_ collection: ArchiveCollection, destination: Int, fromDetail: Bool = false) {
        let controller = SearchController(environment: environment, collection: collection) { [weak self] artifact in
            self?.open(artifact, destination: destination, fromDetail: fromDetail)
        }
        let navigation = split != nil && fromDetail ? histories[destination].detail ?? destinations[destination] : destinations[destination]
        navigation.pushViewController(controller, animated: true)
    }

    private func open(_ artifact: ArtifactSummary, destination: Int, fromDetail: Bool = false) {
        if artifact.mediaType == .collection {
            openCollection(ArchiveCollection(identifier: artifact.identifier, title: artifact.title), destination: destination, fromDetail: fromDetail)
            return
        }
        let controller = ArtifactController(environment: environment, summary: artifact) { [weak self] collection in
            self?.openCollection(collection, destination: destination, fromDetail: true)
        }
        let history = histories[destination]
        if let split {
            if fromDetail, let navigation = history.detail {
                navigation.pushViewController(controller, animated: true)
                return
            }
            let navigation = history.replaceDetail(with: controller)
            split.setViewController(navigation, for: .secondary)
            split.show(.secondary)
        } else { history.pushCompactDetail(controller) }
    }

}

/// Owns one destination's column boundary. Controller identity preserves scroll, selection and child navigation.
@MainActor
final class DestinationNavigationHistory {
    let navigation: UINavigationController
    private(set) var detail: UINavigationController?
    private weak var compactDetailRoot: UIViewController?

    init(navigation: UINavigationController) { self.navigation = navigation }

    @discardableResult
    func replaceDetail(with controller: UIViewController) -> UINavigationController {
        let detail = UINavigationController(rootViewController: controller)
        self.detail = detail
        compactDetailRoot = nil
        return detail
    }

    func pushCompactDetail(_ controller: UIViewController, animated: Bool = true) {
        if compactDetailRoot == nil || !navigation.viewControllers.contains(where: { $0 === compactDetailRoot }) {
            compactDetailRoot = controller
        }
        navigation.pushViewController(controller, animated: animated)
    }

    func collapseDetail() {
        guard let detail, let root = detail.viewControllers.first else { return }
        let stack = detail.viewControllers
        detail.setViewControllers([], animated: false)
        compactDetailRoot = root
        navigation.setViewControllers(navigation.viewControllers + stack, animated: false)
    }

    func expandDetail(bottomInset: CGFloat = 0) {
        guard let root = compactDetailRoot,
              let boundary = navigation.viewControllers.firstIndex(where: { $0 === root }) else {
            detail = nil
            compactDetailRoot = nil
            return
        }
        let stack = navigation.viewControllers
        let detailStack = Array(stack[boundary...])
        navigation.setViewControllers(Array(stack[..<boundary]), animated: false)
        let detail = detail ?? UINavigationController()
        detail.setViewControllers(detailStack, animated: false)
        detail.additionalSafeAreaInsets.bottom = bottomInset
        self.detail = detail
        compactDetailRoot = nil
    }
}

@MainActor
private final class DestinationController: FunstonListController {
    let choose: (Int) -> Void
    private var selectedIndex: Int
    init(selectedIndex: Int, choose: @escaping (Int) -> Void) {
        self.selectedIndex = selectedIndex
        self.choose = choose
        super.init(title: "Funston", appearance: .sidebar)
        apply([FunstonRow(id: "0", title: "Explore", symbol: "safari"), FunstonRow(id: "1", title: "Search", symbol: "magnifyingglass"), FunstonRow(id: "2", title: "Library", symbol: "books.vertical"), FunstonRow(id: "3", title: "Downloads", symbol: "arrow.down.circle")])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func configure(_ cell: UICollectionViewListCell, row: FunstonRow) {
        super.configure(cell, row: row)
        let selected = Int(row.id) == selectedIndex
        cell.accessories = selected ? [.checkmark()] : []
        if selected { cell.accessibilityTraits.insert(.selected) }
    }
    override func selected(_ id: String) {
        guard let index = Int(id) else { return }
        if index != selectedIndex {
            let previous = selectedIndex
            selectedIndex = index
            refreshRow(String(previous)); refreshRow(id)
        }
        choose(index)
    }
}

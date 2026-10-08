import UIKit
import SwiftUI
import Combine
import os

/// Collection provenance gives discovery its structure. Covers are content, not decoration.
@MainActor
final class ExploreController: UICollectionViewController {
    /// The shelf above the collections. Its key can't collide with a collection
    /// identifier because Internet Archive identifiers have no spaces.
    private static let continueSection = "continue listening"
    private enum Metrics {
        static let sideInset: CGFloat = 20
        static let tileSpacing: CGFloat = 16
        /// Gap between the heading's last line and the covers.
        static let shelfTop: CGFloat = 4
        /// Gap under a shelf's titles before the next heading.
        static let shelfBottom: CGFloat = 16
        static let estimatedTileHeight: CGFloat = 280
        static let estimatedHeaderHeight: CGFloat = 90
    }
    private static let continuePrefix = "continue:"
    private static let logger = Logger(subsystem: "com.camden.Funston", category: "Explore")
    private let environment: AppEnvironment
    private let repository: CachingArchiveRepository
    private let openCollection: (ArchiveCollection) -> Void
    private let openArtifact: (ArtifactSummary) -> Void
    private let collections = ArchiveCollection.curated
    private var contents: [String: [ArtifactSummary]] = [:]
    private var errors: [String: String] = [:]
    private var stale = Set<String>()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var source: UICollectionViewDiffableDataSource<String, String>!
    private var artifacts: [String: ArtifactSummary] = [:]
    private var continueItems: [ContinueListeningItem] = []
    private var continueByKey: [String: ContinueListeningItem] = [:]
    private var continueTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private let sizingCell = ExploreArtifactCell(frame: .zero)
    private let sizingStatusCell = UICollectionViewCell(frame: .zero)
    private var shelfHeights: [String: (width: CGFloat, category: UIContentSizeCategory, height: CGFloat)] = [:]
    private enum Status: Equatable {
        case loading, empty
        case error(String, hasItems: Bool)
    }
    private var renderedStatuses: [String: Status] = [:]
    private var lastAppliedHideUnsupportedMedia: Bool
    private var pendingVisibilityReloads = Set<String>()

    init(environment: AppEnvironment, openCollection: @escaping (ArchiveCollection) -> Void, openArtifact: @escaping (ArtifactSummary) -> Void) {
        self.environment = environment
        lastAppliedHideUnsupportedMedia = environment.settings.hideUnsupportedMedia
        repository = environment.repository
        self.openCollection = openCollection; self.openArtifact = openArtifact
        super.init(collectionViewLayout: UICollectionViewFlowLayout())
        title = "Explore"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { tasks.values.forEach { $0.cancel() }; continueTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .systemBackground
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.contentInset.bottom = 32
        // Only headers and the vertical accessibility layout self-size. Horizontal
        // shelves get their final height before scrolling, including unseen tiles.
        collectionView.selfSizingInvalidation = .enabled
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: ExploreController, _: UITraitCollection) in
            controller.shelfHeights.removeAll()
            controller.collectionView.setCollectionViewLayout(controller.makeLayout(), animated: false)
        }
        let artifactCell = UICollectionView.CellRegistration<ExploreArtifactCell, String> { [weak self] cell, _, id in
            guard let self, let artifact = self.artifacts[id] else { return }
            cell.configure(artifact: artifact) { [weak self] in self?.open(artifact) }
        }
        let continueCell = UICollectionView.CellRegistration<ExploreArtifactCell, String> { [weak self] cell, _, id in
            guard let self, let item = self.continueByKey[id] else { return }
            cell.configure(continuing: item) { [weak self] in self?.resume(item) }
        }
        let statusCell = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let self else { return }
                cell.contentConfiguration = self.statusConfiguration(for: String(id.dropFirst("status:".count)))
                cell.isAccessibilityElement = false
                cell.accessibilityIdentifier = nil
        }
        let header = UICollectionView.SupplementaryRegistration<ExploreSectionHeader>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, index in
            self?.configure(header, section: index.section)
        }
        source = UICollectionViewDiffableDataSource<String, String>(collectionView: collectionView) { [weak self] collection, index, id in
            if self?.continueByKey[id] != nil {
                return collection.dequeueConfiguredReusableCell(using: continueCell, for: index, item: id)
            }
            if self?.artifacts[id] != nil {
                return collection.dequeueConfiguredReusableCell(using: artifactCell, for: index, item: id)
            }
            return collection.dequeueConfiguredReusableCell(using: statusCell, for: index, item: id)
        }
        source.supplementaryViewProvider = { collection, _, index in
            collection.dequeueConfiguredReusableSupplementary(using: header, for: index)
        }
        render()
        subscribeToPlayback()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if lastAppliedHideUnsupportedMedia != environment.settings.hideUnsupportedMedia {
            lastAppliedHideUnsupportedMedia = environment.settings.hideUnsupportedMedia
            for identifier in Set(contents.keys).union(errors.keys).union(tasks.keys) {
                // Let an existing load settle before replacing it; it must not clear a newer task.
                if tasks[identifier] != nil { pendingVisibilityReloads.insert(identifier) }
                else { load(identifier, force: true) }
            }
        }
        refreshContinueListening()
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            let traits = self?.traitCollection ?? environment.traitCollection
            let accessibility = traits.preferredContentSizeCategory.isAccessibilityCategory
            let available = max(1, environment.container.effectiveContentSize.width - 2 * Metrics.sideInset)
            let count = accessibility || available < 300 ? 1 : max(2, Int((available + Metrics.tileSpacing) / 208))
            let width = (available - CGFloat(count - 1) * Metrics.tileSpacing) / CGFloat(count)
            let height: NSCollectionLayoutDimension = accessibility ? .estimated(Metrics.estimatedTileHeight) : .absolute(self?.shelfHeight(section: index, width: width, traits: traits) ?? Metrics.estimatedTileHeight)
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(width), heightDimension: height))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .absolute(available), heightDimension: height), subitems: Array(repeating: item, count: count))
            group.interItemSpacing = .fixed(Metrics.tileSpacing)
            let section = NSCollectionLayoutSection(group: group)
            section.orthogonalScrollingBehavior = accessibility ? .none : .groupPaging
            section.interGroupSpacing = 2 * Metrics.sideInset
            section.contentInsets = .init(top: Metrics.shelfTop, leading: Metrics.sideInset, bottom: Metrics.shelfBottom, trailing: Metrics.sideInset)
            // Let UIKit clip the scrolling viewport. Changing alpha at its edges
            // makes outgoing and incoming tiles blink during every partial swipe.
            section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(Metrics.estimatedHeaderHeight)), elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)]
            return section
        }
    }

    private func shelfHeight(section: Int, width: CGFloat, traits: UITraitCollection) -> CGFloat {
        guard let identifier = source?.sectionIdentifier(for: section) else { return Metrics.estimatedTileHeight }
        let category = traits.preferredContentSizeCategory
        if let cached = shelfHeights[identifier], cached.width == width, cached.category == category { return cached.height }
        sizingCell.traitOverrides.preferredContentSizeCategory = category
        sizingStatusCell.traitOverrides.preferredContentSizeCategory = category
        var height: CGFloat = 1
        for key in source.snapshot().itemIdentifiers(inSection: identifier) {
            let cell: UICollectionViewCell
            if let item = continueByKey[key] {
                sizingCell.configure(continuing: item, open: {})
                height = max(height, sizingCell.fittingHeight(width: width, traits: traits))
                continue
            } else if let artifact = artifacts[key] {
                sizingCell.configure(artifact: artifact, open: {})
                height = max(height, sizingCell.fittingHeight(width: width, traits: traits))
                continue
            } else {
                sizingStatusCell.contentConfiguration = statusConfiguration(for: identifier, traits: traits)
                cell = sizingStatusCell
            }
            height = max(height, cell.contentView.systemLayoutSizeFitting(
                CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel).height)
        }
        height = ceil(height)
        shelfHeights[identifier] = (width, category, height)
        return height
    }

    private func statusConfiguration(for collectionID: String, traits: UITraitCollection? = nil) -> UIHostingConfiguration<some View, EmptyView> {
        let status = status(for: collectionID)
        let textSize = traits.flatMap { DynamicTypeSize($0.preferredContentSizeCategory) }
        return UIHostingConfiguration {
            VStack(alignment: .leading, spacing: 12) {
                switch status {
                case let .error(error, hasItems):
                    Text(hasItems ? "Could not refresh" : "Could not load items").font(.headline)
                    Text(error).font(.subheadline).foregroundStyle(Color.funstonSecondaryText)
                    Button("Try Again") { [weak self] in self?.load(collectionID, force: true) }.frame(minHeight: 44)
                case .empty:
                    Text("No items to show").font(.headline)
                    Text("Open the collection to browse it.").font(.subheadline).foregroundStyle(Color.funstonSecondaryText)
                case .loading:
                    ProgressView().accessibilityLabel("Loading")
                    Text("Loading from Internet Archive…").font(.subheadline).foregroundStyle(Color.funstonSecondaryText)
                }
            }.frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
                .transformEnvironment(\.dynamicTypeSize) { size in
                    if let textSize { size = textSize }
                }
        }.margins(.all, 0)
    }

    private func status(for collectionID: String) -> Status {
        if let error = errors[collectionID] { return .error(error, hasItems: contents[collectionID]?.isEmpty == false) }
        return contents[collectionID]?.isEmpty == true && tasks[collectionID] == nil ? .empty : .loading
    }

    override func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? ExploreArtifactCell)?.loadArtwork()
        if let collection = collection(at: indexPath.section) { load(collection.identifier) }
    }

    override func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? ExploreArtifactCell)?.cancelArtwork()
    }

    private func load(_ identifier: String, force: Bool = false) {
        guard tasks[identifier] == nil, force || contents[identifier] == nil && errors[identifier] == nil else { return }
        errors[identifier] = nil
        let repository = repository
        let scope: MediaType = switch identifier {
        case "oldtimeradio", "etree": .audio
        case "texts": .texts
        case "prelinger": .movies
        default: .all
        }
        tasks[identifier] = Task { [weak self] in
            do {
                for try await update in repository.searchUpdates(SearchRequest(scope: scope, pageSize: 6, collection: identifier)) {
                    try Task.checkCancellation()
                    guard let self else { return }
                    self.contents[identifier] = update.value.items
                    self.errors[identifier] = update.refreshError
                    if update.freshness == .stale { self.stale.insert(identifier) } else { self.stale.remove(identifier) }
                    self.render()
                }
            } catch is CancellationError {} catch {
                self?.errors[identifier] = archiveMessage(error)
                self?.render()
            }
            self?.tasks[identifier] = nil
            self?.render()
            if self?.pendingVisibilityReloads.remove(identifier) != nil { self?.load(identifier, force: true) }
        }
        if force { render() }
    }

    private func render() {
        guard source != nil else { return }
        // At the very top there is nothing to hold in place, and the shelf
        // appearing above the collections should be seen.
        let atTop = collectionView.contentOffset.y <= -collectionView.adjustedContentInset.top + 0.5
        let anchor: (section: String, relativeY: CGFloat)? = {
            guard collectionView.window != nil, !atTop, !collectionView.isDragging, !collectionView.isDecelerating,
                  let section = collectionView.indexPathsForVisibleItems.map(\.section).min(),
                  let identifier = source.sectionIdentifier(for: section),
                  let attributes = collectionView.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section)) else { return nil }
            return (identifier, attributes.frame.minY - collectionView.contentOffset.y)
        }()
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        var nextArtifacts: [String: ArtifactSummary] = [:]
        var nextContinue: [String: ContinueListeningItem] = [:]
        if !continueItems.isEmpty {
            snapshot.appendSections([Self.continueSection])
            for item in continueItems {
                let key = Self.continuePrefix + item.summary.identifier
                nextContinue[key] = item
                snapshot.appendItems([key])
            }
        }
        for collection in collections {
            snapshot.appendSections([collection.identifier])
            if let items = contents[collection.identifier], !items.isEmpty {
                for artifact in items {
                    let key = collection.identifier + ":" + artifact.identifier
                    nextArtifacts[key] = artifact
                    snapshot.appendItems([key])
                }
                if errors[collection.identifier] != nil || stale.contains(collection.identifier) && tasks[collection.identifier] != nil { snapshot.appendItems(["status:" + collection.identifier]) }
            } else {
                snapshot.appendItems(["status:" + collection.identifier])
            }
        }
        let previous = source.snapshot()
        let existing = Set(previous.itemIdentifiers)
        let nextStatuses = Dictionary(uniqueKeysWithValues: snapshot.itemIdentifiers.filter { $0.hasPrefix("status:") }.map {
            ($0, status(for: String($0.dropFirst("status:".count))))
        })
        let changed = snapshot.itemIdentifiers.filter {
            existing.contains($0) && (artifacts[$0] != nextArtifacts[$0] || continueByKey[$0] != nextContinue[$0] || renderedStatuses[$0] != nextStatuses[$0])
        }
        guard previous.sectionIdentifiers != snapshot.sectionIdentifiers || previous.itemIdentifiers != snapshot.itemIdentifiers || !changed.isEmpty else {
            updateVisibleHeaders()
            return
        }
        snapshot.reconfigureItems(changed)
        artifacts = nextArtifacts
        continueByKey = nextContinue
        renderedStatuses = nextStatuses
        shelfHeights.removeAll()
        source.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            if let anchor, !self.collectionView.isDragging, !self.collectionView.isDecelerating,
               let section = self.source.snapshot().indexOfSection(anchor.section) {
                self.collectionView.layoutIfNeeded()
                if let attributes = self.collectionView.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section)) {
                    let minimum = -self.collectionView.adjustedContentInset.top
                    let maximum = max(minimum, self.collectionView.contentSize.height - self.collectionView.bounds.height + self.collectionView.adjustedContentInset.bottom)
                    let y = min(maximum, max(minimum, attributes.frame.minY - anchor.relativeY))
                    if abs(y - self.collectionView.contentOffset.y) > 0.5 { self.collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false) }
                }
            }
            self.updateVisibleHeaders()
        }
    }

    private func updateVisibleHeaders() {
        for index in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader) {
            guard let header = collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: index) as? ExploreSectionHeader else { continue }
            configure(header, section: index.section)
        }
    }

    private func collection(at section: Int) -> ArchiveCollection? {
        guard let identifier = source.sectionIdentifier(for: section) else { return nil }
        return collections.first { $0.identifier == identifier }
    }

    private func configure(_ header: ExploreSectionHeader, section: Int) {
        if let collection = collection(at: section) {
            header.configure(collection: collection, cached: stale.contains(collection.identifier)) { [weak self] in self?.openCollection(collection) }
        } else {
            header.configure(heading: "Continue listening")
        }
    }

    private func subscribeToPlayback() {
        let playback = environment.playback
        // Pausing and switching recordings are when a saved position changes
        // enough to matter. The pause is written asynchronously, so wait briefly.
        let paused = playback.$phase.removeDuplicates().filter { $0 == .paused || $0 == .ended }.map { _ in () }
        let switched = playback.$context.map { $0.map { $0.artifact.identifier + "/" + $0.file.name } }.removeDuplicates().map { _ in () }
        paused.merge(with: switched)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.viewIfLoaded?.window != nil else { return }
                self.refreshContinueListening()
            }
            .store(in: &subscriptions)
    }

    private func refreshContinueListening() {
        continueTask?.cancel()
        let store = environment.store, repository = repository, downloads = environment.downloads
        continueTask = Task { [weak self] in
            let bookmarks: [PlaybackBookmark]
            do { bookmarks = try await store.recentPlaybackPositions(limit: ContinueListening.bookmarkLimit) }
            catch {
                Self.logger.error("Saved positions unavailable: \(error.localizedDescription, privacy: .public)")
                return
            }
            let items = await ContinueListening.items(
                bookmarks: bookmarks,
                detail: { try await repository.detail(identifier: $0) },
                download: { await downloads.completedRecord(identifier: $0, fileName: $1) })
            guard !Task.isCancelled, let self else { return }
            self.continueTask = nil
            guard items != self.continueItems else { return }
            self.continueItems = items
            self.render()
        }
    }

    /// Picks the recording back up through the same paths as the item page and
    /// Downloads; the player restores the saved position itself.
    private func resume(_ item: ContinueListeningItem) {
        let playback = environment.playback
        if let context = playback.context, context.artifact.identifier == item.summary.identifier,
           context.file.name == item.fileName {
            playback.play()
        } else if let download = item.download {
            playback.playDownloaded(download)
        } else {
            playback.load(artifact: item.summary, tracks: item.tracks, trackIndex: item.trackIndex)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let key = source.itemIdentifier(for: indexPath) else { return }
        if let item = continueByKey[key] { resume(item) }
        else if let artifact = artifacts[key] { open(artifact) }
    }

    private func open(_ artifact: ArtifactSummary) {
        if artifact.mediaType == .collection {
            openCollection(ArchiveCollection(identifier: artifact.identifier, title: artifact.title))
        } else { openArtifact(artifact) }
    }
}

@MainActor
final class ExploreArtifactCell: UICollectionViewCell {
    nonisolated static let maximumCoverHeight: CGFloat = 176

    private enum Metrics {
        static let artworkHeight: CGFloat = ExploreArtifactCell.maximumCoverHeight
        static let artworkCornerRadius: CGFloat = 4
        static let placeholderSymbolSide: CGFloat = 36
        static let textSpacing: CGFloat = 10
        static let bottomPadding: CGFloat = 8
        /// Keeps the time-left line with its bar rather than a full text gap away.
        static let progressSpacing: CGFloat = 6
    }

    private let button = UIButton(type: .custom)
    private let artwork = UIImageView()
    private let placeholder = UIImageView()
    private let placeholderSurface = UIView()
    private let titleLabel = UILabel()
    private let metadataLabel = UILabel()
    /// Continue listening only: how far in, as a bar and in words.
    private let progressBar = UIProgressView(progressViewStyle: .default)
    private let progressLabel = UILabel()
    private let progressStack = UIStackView()
    private var identifier: String?
    private var action: UIAction?
    private var artworkTask: Task<Void, Never>?
    private var hasArtwork = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        contentView.backgroundColor = .systemBackground
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isAccessibilityElement = true
        contentView.addSubview(button)

        let imageSurface = UIView()
        placeholderSurface.backgroundColor = .secondarySystemBackground
        placeholderSurface.layer.cornerRadius = Metrics.artworkCornerRadius
        imageSurface.backgroundColor = .secondarySystemBackground
        imageSurface.layer.cornerRadius = Metrics.artworkCornerRadius
        imageSurface.clipsToBounds = true
        artwork.contentMode = .scaleAspectFit
        placeholder.contentMode = .scaleAspectFit
        placeholder.tintColor = .tertiaryLabel
        for view in [placeholderSurface, artwork, placeholder] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isAccessibilityElement = false
            imageSurface.addSubview(view)
        }
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        metadataLabel.font = .preferredFont(forTextStyle: .subheadline)
        metadataLabel.textColor = .funstonSecondaryLabel
        progressLabel.font = .preferredFont(forTextStyle: .footnote)
        progressLabel.textColor = .funstonSecondaryLabel
        for label in [titleLabel, metadataLabel, progressLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.isAccessibilityElement = false
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        progressBar.trackTintColor = .tertiarySystemFill
        progressBar.isAccessibilityElement = false
        progressStack.axis = .vertical; progressStack.spacing = Metrics.progressSpacing
        progressStack.addArrangedSubview(progressBar)
        progressStack.addArrangedSubview(progressLabel)
        progressStack.isHidden = true
        let stack = UIStackView(arrangedSubviews: [imageSurface, titleLabel, metadataLabel, progressStack])
        stack.axis = .vertical; stack.spacing = Metrics.textSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isUserInteractionEnabled = false
        button.addSubview(stack)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            stack.topAnchor.constraint(equalTo: button.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: button.bottomAnchor, constant: -Metrics.bottomPadding),
            placeholderSurface.leadingAnchor.constraint(equalTo: imageSurface.leadingAnchor),
            placeholderSurface.trailingAnchor.constraint(equalTo: imageSurface.trailingAnchor),
            placeholderSurface.topAnchor.constraint(equalTo: imageSurface.topAnchor),
            placeholderSurface.bottomAnchor.constraint(equalTo: imageSurface.bottomAnchor),
            artwork.leadingAnchor.constraint(equalTo: imageSurface.leadingAnchor),
            artwork.trailingAnchor.constraint(equalTo: imageSurface.trailingAnchor),
            artwork.topAnchor.constraint(equalTo: imageSurface.topAnchor),
            artwork.bottomAnchor.constraint(equalTo: imageSurface.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: imageSurface.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: imageSurface.centerYAnchor),
            placeholder.widthAnchor.constraint(equalToConstant: Metrics.placeholderSymbolSide),
            placeholder.heightAnchor.constraint(equalToConstant: Metrics.placeholderSymbolSide)
        ])
        imageSurface.heightAnchor.constraint(equalToConstant: Metrics.artworkHeight).isActive = true
        updateTextLayout()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: ExploreArtifactCell, _: UITraitCollection) in cell.updateTextLayout() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { artworkTask?.cancel() }

    func configure(artifact: ArtifactSummary, open: @escaping () -> Void) {
        let metadata = [(artifact.creatorDescription.isEmpty ? nil : artifact.creatorDescription), artifact.displayYear].compactMap { $0 }.joined(separator: " · ")
        show(artifact, metadata: metadata, open: open)
        progressStack.isHidden = true
        button.accessibilityLabel = artifact.spokenSummary
        button.accessibilityValue = nil
        button.accessibilityIdentifier = "explore.artifact." + artifact.identifier
    }

    /// A Continue listening tile: the same cover and title, with the recording
    /// (for items with several) or creator underneath, then time left.
    func configure(continuing item: ContinueListeningItem, open: @escaping () -> Void) {
        let artifact = item.summary
        show(artifact, metadata: item.trackTitle.map(MetadataFormatter.title) ?? (artifact.creatorDescription.isEmpty ? nil : artifact.creatorDescription) ?? "", open: open)
        progressBar.progress = Float(item.fractionPlayed ?? 0)
        progressBar.isHidden = item.fractionPlayed == nil
        progressLabel.text = item.progressDescription
        progressStack.isHidden = false
        button.accessibilityLabel = ([artifact.title, item.trackTitle.map(MetadataFormatter.title), (artifact.creatorDescription.isEmpty ? nil : artifact.creatorDescription)].compactMap { $0 }).joined(separator: ", ")
        button.accessibilityValue = item.progressDescription
        button.accessibilityIdentifier = "explore.continue." + artifact.identifier
    }

    private func show(_ artifact: ArtifactSummary, metadata: String, open: @escaping () -> Void) {
        if identifier != artifact.identifier {
            cancelArtwork(); identifier = artifact.identifier
            showPlaceholder()
        }
        placeholder.image = UIImage(systemName: artifact.mediaType.artworkSymbol)
        titleLabel.text = artifact.title
        metadataLabel.text = metadata
        metadataLabel.isHidden = metadata.isEmpty
        if let action { button.removeAction(action, for: .primaryActionTriggered) }
        let next = UIAction { _ in open() }; action = next
        button.addAction(next, for: .primaryActionTriggered)
        updateTextLayout()
        if window != nil { loadArtwork() }
    }

    /// Detached sizing cells don't inherit the screen's traits. Supply them
    /// explicitly so the measured fonts match the visible tiles at every size.
    func fittingHeight(width: CGFloat, traits: UITraitCollection) -> CGFloat {
        // A detached label would otherwise rescale an explicitly supplied font
        // back to its own default traits while Auto Layout measures it.
        for label in [titleLabel, metadataLabel, progressLabel] { label.adjustsFontForContentSizeCategory = false }
        updateTextLayout(traits: traits)
        return contentView.systemLayoutSizeFitting(CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
    }

    private func updateTextLayout(traits: UITraitCollection? = nil) {
        let traits = traits ?? traitCollection
        titleLabel.font = .preferredFont(forTextStyle: .headline, compatibleWith: traits)
        metadataLabel.font = .preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        progressLabel.font = .preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        let large = traits.preferredContentSizeCategory.isAccessibilityCategory
        titleLabel.numberOfLines = large ? 0 : 3
        metadataLabel.numberOfLines = large ? 0 : 2
        progressLabel.numberOfLines = large ? 0 : 1
        setNeedsLayout()
    }

    func loadArtwork() {
        guard let identifier, artworkTask == nil, !hasArtwork else { return }
        let scale = traitCollection.displayScale
        artworkTask = Task { [weak self] in
            let result = try? await ArtworkPipeline.shared.image(url: ArchiveURLs.thumbnail(identifier: identifier), pointSize: CGSize(width: 192, height: 176), scale: scale)
            guard !Task.isCancelled, let self, self.identifier == identifier else { return }
            artworkTask = nil
            if let image = result?.value, image.size.width > 0, image.size.height > 0 {
                artwork.image = image; hasArtwork = true
                placeholder.isHidden = true; placeholderSurface.isHidden = true
            }
        }
    }


    private func showPlaceholder() {
        artwork.image = nil; hasArtwork = false
        placeholder.isHidden = false; placeholderSurface.isHidden = false
    }

    func cancelArtwork() { artworkTask?.cancel(); artworkTask = nil }
    override func prepareForReuse() {
        super.prepareForReuse()
        cancelArtwork(); identifier = nil; showPlaceholder()
        if let action { button.removeAction(action, for: .primaryActionTriggered) }
        action = nil
    }
}

@MainActor
private final class ExploreSectionHeader: UICollectionReusableView {
    /// Above the heading, between the previous shelf's titles and this one.
    private static let topSpacing: CGFloat = 8
    /// Below "Most downloaded", before the covers.
    private static let bottomSpacing: CGFloat = 8
    private let title = UIButton(type: .system)
    /// Shelves that aren't a collection have a plain heading, not a Browse button.
    private let heading = UILabel()
    private let subtitle = UILabel()
    private var action: UIAction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.contentHorizontalAlignment = .leading
        subtitle.numberOfLines = 0
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.textColor = .funstonSecondaryLabel
        heading.numberOfLines = 0
        heading.font = .preferredFont(forTextStyle: .title2)
        heading.adjustsFontForContentSizeCategory = true
        heading.textColor = .label
        heading.accessibilityTraits = .header
        heading.isHidden = true
        let stack = UIStackView(arrangedSubviews: [title, heading, subtitle])
        stack.axis = .vertical; stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Just below required, so the stack can collapse whichever of the
        // button or the heading is hidden.
        let minimumHeights = [title, heading].map { $0.heightAnchor.constraint(greaterThanOrEqualToConstant: 44) }
        minimumHeights.forEach { $0.priority = .required - 1 }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.topSpacing), stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomSpacing)
        ] + minimumHeights)
    }

    func configure(heading text: String) {
        title.isHidden = true
        subtitle.isHidden = true
        heading.isHidden = false
        heading.text = text
        if let action { title.removeAction(action, for: .primaryActionTriggered) }
        action = nil
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(collection: ArchiveCollection, cached: Bool, open: @escaping () -> Void) {
        title.isHidden = false
        subtitle.isHidden = false
        heading.isHidden = true
        var configuration = UIButton.Configuration.plain()
        configuration.title = collection.title
        configuration.image = UIImage(systemName: "chevron.right")
        configuration.imagePlacement = .trailing; configuration.imagePadding = 10
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = .label
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var output = incoming; output.font = .preferredFont(forTextStyle: .title2); return output
        }
        title.configuration = configuration
        title.titleLabel?.numberOfLines = 0
        title.titleLabel?.adjustsFontForContentSizeCategory = true
        title.accessibilityLabel = "Browse \(collection.title)"
        title.accessibilityIdentifier = collection.identifier
        if let action { title.removeAction(action, for: .primaryActionTriggered) }
        let next = UIAction { _ in open() }; action = next
        title.addAction(next, for: .primaryActionTriggered)
        subtitle.text = cached ? "Most downloaded (saved copy)" : "Most downloaded"
    }
}

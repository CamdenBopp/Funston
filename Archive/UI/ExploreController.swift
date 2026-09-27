import UIKit
import SwiftUI

/// Collection provenance gives discovery its structure. Covers are content, not decoration.
@MainActor
final class ExploreController: UICollectionViewController {
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

    init(environment: AppEnvironment, openCollection: @escaping (ArchiveCollection) -> Void, openArtifact: @escaping (ArtifactSummary) -> Void) {
        repository = environment.repository
        self.openCollection = openCollection; self.openArtifact = openArtifact
        super.init(collectionViewLayout: Self.layout(accessibility: false))
        title = "Explore"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { tasks.values.forEach { $0.cancel() } }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .systemBackground
        collectionView.contentInset.bottom = 24
        collectionView.setCollectionViewLayout(Self.layout(accessibility: traitCollection.preferredContentSizeCategory.isAccessibilityCategory), animated: false)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: ExploreController, _: UITraitCollection) in
            controller.collectionView.setCollectionViewLayout(Self.layout(accessibility: controller.traitCollection.preferredContentSizeCategory.isAccessibilityCategory), animated: false)
        }
        let artifactCell = UICollectionView.CellRegistration<ExploreArtifactCell, String> { [weak self] cell, _, id in
            guard let self, let artifact = self.artifacts[id] else { return }
            cell.configure(artifact: artifact) { [weak self] in self?.open(artifact) }
        }
        let statusCell = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let self else { return }
                let collectionID = String(id.dropFirst("status:".count))
                let error = self.errors[collectionID]
                cell.contentConfiguration = UIHostingConfiguration {
                    VStack(alignment: .leading, spacing: 12) {
                        if let error {
                            Text(self.contents[collectionID]?.isEmpty == false ? "Saved artifacts" : "Could not load artifacts").font(.headline)
                            Text(error).font(.subheadline).foregroundStyle(Color.archiveSecondaryText)
                            Button("Try Again") { [weak self] in self?.load(collectionID, force: true) }.frame(minHeight: 44)
                        } else if self.contents[collectionID]?.isEmpty == true && self.tasks[collectionID] == nil {
                            Text("No artifacts available").font(.headline)
                            Text("Browse this collection for more information.").font(.subheadline).foregroundStyle(Color.archiveSecondaryText)
                        } else {
                            ProgressView().accessibilityLabel("Loading artifacts")
                            Text("Loading from Internet Archive…").font(.subheadline).foregroundStyle(Color.archiveSecondaryText)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
                }.margins(.all, 0)
                cell.isAccessibilityElement = false
                cell.accessibilityIdentifier = nil
        }
        let header = UICollectionView.SupplementaryRegistration<ExploreSectionHeader>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, index in
            guard let self else { return }
            let collection = self.collections[index.section]
            header.configure(collection: collection, cached: self.stale.contains(collection.identifier)) { [weak self] in self?.openCollection(collection) }
        }
        source = UICollectionViewDiffableDataSource<String, String>(collectionView: collectionView) { [weak self] collection, index, id in
            if self?.artifacts[id] != nil {
                return collection.dequeueConfiguredReusableCell(using: artifactCell, for: index, item: id)
            }
            return collection.dequeueConfiguredReusableCell(using: statusCell, for: index, item: id)
        }
        source.supplementaryViewProvider = { collection, _, index in
            collection.dequeueConfiguredReusableSupplementary(using: header, for: index)
        }
        render()
    }

    private static func layout(accessibility: Bool) -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let width = accessibility ? environment.container.effectiveContentSize.width - 40 : min(192, max(156, environment.container.effectiveContentSize.width * 0.43))
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(280)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .absolute(width), heightDimension: .estimated(280)), subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.orthogonalScrollingBehavior = accessibility ? .none : .continuousGroupLeadingBoundary
            section.interGroupSpacing = 16
            section.contentInsets = .init(top: 4, leading: 20, bottom: 24, trailing: 20)
            section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(106)), elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)]
            return section
        }
    }

    override func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? ExploreArtifactCell)?.loadArtwork()
        load(collections[indexPath.section].identifier)
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
        }
        if force { render() }
    }

    private func render() {
        guard source != nil else { return }
        let anchor: (section: Int, relativeY: CGFloat)? = {
            guard collectionView.window != nil, !collectionView.isDragging, !collectionView.isDecelerating,
                  let section = collectionView.indexPathsForVisibleItems.map(\.section).min(),
                  let attributes = collectionView.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section)) else { return nil }
            return (section, attributes.frame.minY - collectionView.contentOffset.y)
        }()
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        var nextArtifacts: [String: ArtifactSummary] = [:]
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
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { existing.contains($0) && (artifacts[$0] != nextArtifacts[$0] || $0.hasPrefix("status:")) })
        artifacts = nextArtifacts
        source.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            if let anchor, !self.collectionView.isDragging, !self.collectionView.isDecelerating {
                self.collectionView.layoutIfNeeded()
                if let attributes = self.collectionView.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: anchor.section)) {
                    let minimum = -self.collectionView.adjustedContentInset.top
                    let maximum = max(minimum, self.collectionView.contentSize.height - self.collectionView.bounds.height + self.collectionView.adjustedContentInset.bottom)
                    let y = min(maximum, max(minimum, attributes.frame.minY - anchor.relativeY))
                    if abs(y - self.collectionView.contentOffset.y) > 0.5 { self.collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false) }
                }
            }
            for index in self.collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader) {
                guard let header = self.collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: index) as? ExploreSectionHeader else { continue }
                let collection = self.collections[index.section]
                header.configure(collection: collection, cached: self.stale.contains(collection.identifier)) { [weak self] in self?.openCollection(collection) }
            }
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let key = source.itemIdentifier(for: indexPath), let artifact = artifacts[key] else { return }
        open(artifact)
    }

    private func open(_ artifact: ArtifactSummary) {
        if artifact.mediaType == .collection {
            openCollection(ArchiveCollection(identifier: artifact.identifier, title: artifact.title, description: ""))
        } else { openArtifact(artifact) }
    }
}

@MainActor
private final class ExploreArtifactCell: UICollectionViewCell {
    private let button = UIButton(type: .custom)
    private let artwork = UIImageView()
    private let placeholder = UIImageView()
    private let titleLabel = UILabel()
    private let metadataLabel = UILabel()
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
        imageSurface.backgroundColor = .secondarySystemBackground
        imageSurface.layer.cornerRadius = 4
        imageSurface.clipsToBounds = true
        artwork.contentMode = .scaleAspectFit
        placeholder.contentMode = .scaleAspectFit
        placeholder.tintColor = .tertiaryLabel
        for image in [artwork, placeholder] {
            image.translatesAutoresizingMaskIntoConstraints = false
            image.isAccessibilityElement = false
            imageSurface.addSubview(image)
        }
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        metadataLabel.font = .preferredFont(forTextStyle: .subheadline)
        metadataLabel.textColor = .archiveSecondaryLabel
        for label in [titleLabel, metadataLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.isAccessibilityElement = false
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        let stack = UIStackView(arrangedSubviews: [imageSurface, titleLabel, metadataLabel])
        stack.axis = .vertical; stack.spacing = 10
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
            stack.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -8),
            imageSurface.heightAnchor.constraint(equalToConstant: 176),
            artwork.leadingAnchor.constraint(equalTo: imageSurface.leadingAnchor, constant: 8),
            artwork.trailingAnchor.constraint(equalTo: imageSurface.trailingAnchor, constant: -8),
            artwork.topAnchor.constraint(equalTo: imageSurface.topAnchor, constant: 8),
            artwork.bottomAnchor.constraint(equalTo: imageSurface.bottomAnchor, constant: -8),
            placeholder.centerXAnchor.constraint(equalTo: imageSurface.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: imageSurface.centerYAnchor),
            placeholder.widthAnchor.constraint(equalToConstant: 36),
            placeholder.heightAnchor.constraint(equalToConstant: 36)
        ])
        updateTextLayout()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: ExploreArtifactCell, _: UITraitCollection) in cell.updateTextLayout() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { artworkTask?.cancel() }

    func configure(artifact: ArtifactSummary, open: @escaping () -> Void) {
        if identifier != artifact.identifier {
            cancelArtwork(); identifier = artifact.identifier; hasArtwork = false
            artwork.image = nil; placeholder.isHidden = false
        }
        placeholder.image = UIImage(systemName: artifact.mediaType.artworkSymbol)
        titleLabel.text = artifact.title
        let metadata = [artifact.creators.first, artifact.date.map { String($0.prefix(4)) }].compactMap { $0 }.joined(separator: " · ")
        metadataLabel.text = metadata
        metadataLabel.isHidden = metadata.isEmpty
        button.accessibilityLabel = [artifact.title, artifact.rowSubtitle].joined(separator: ". ")
        button.accessibilityIdentifier = "explore.artifact." + artifact.identifier
        if let action { button.removeAction(action, for: .primaryActionTriggered) }
        let next = UIAction { _ in open() }; action = next
        button.addAction(next, for: .primaryActionTriggered)
        updateTextLayout()
        if window != nil { loadArtwork() }
    }

    private func updateTextLayout() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        titleLabel.numberOfLines = large ? 0 : 3
        metadataLabel.numberOfLines = large ? 0 : 2
        setNeedsLayout()
    }

    func loadArtwork() {
        guard let identifier, artworkTask == nil, !hasArtwork else { return }
        let scale = traitCollection.displayScale
        artworkTask = Task { [weak self] in
            let result = try? await ArtworkPipeline.shared.image(url: ArchiveURLs.thumbnail(identifier: identifier), pointSize: CGSize(width: 192, height: 176), scale: scale)
            guard !Task.isCancelled, let self, self.identifier == identifier else { return }
            artworkTask = nil
            if let image = result?.value {
                artwork.image = image; hasArtwork = true; placeholder.isHidden = true
            }
        }
    }

    func cancelArtwork() { artworkTask?.cancel(); artworkTask = nil }
    override func prepareForReuse() {
        super.prepareForReuse()
        cancelArtwork(); identifier = nil; artwork.image = nil; hasArtwork = false
        if let action { button.removeAction(action, for: .primaryActionTriggered) }
        action = nil
    }
}

@MainActor
private final class ExploreSectionHeader: UICollectionReusableView {
    private let title = UIButton(type: .system)
    private let subtitle = UILabel()
    private var action: UIAction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.contentHorizontalAlignment = .leading
        subtitle.numberOfLines = 0
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.textColor = .archiveSecondaryLabel
        let stack = UIStackView(arrangedSubviews: [title, subtitle])
        stack.axis = .vertical; stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12), stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            title.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(collection: ArchiveCollection, cached: Bool, open: @escaping () -> Void) {
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
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            subtitle.text = cached ? "Saved results" : "Most downloaded"
        } else {
            subtitle.text = cached ? "Saved results · Most downloaded" : "Most downloaded · \(collection.description)"
        }
    }
}

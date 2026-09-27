import UIKit

struct ArchiveRow: Hashable {
    let id: String
    let title: String
    var subtitle: String? = nil
    var navigates = true
    var symbol: String? = nil
    var artworkIdentifier: String? = nil
    var mediaType: MediaType = .unknown
}

@MainActor
class ArchiveListController: UICollectionViewController {
    private(set) var rows: [ArchiveRow] = []
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var byID: [String: ArchiveRow] = [:]
    private var rowIndices: [String: Int] = [:]
    private var hasSnapshot = false
    private var snapshotGeneration = 0

    init(title: String, appearance: UICollectionLayoutListConfiguration.Appearance = .plain) {
        let configuration = UICollectionLayoutListConfiguration(appearance: appearance)
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        collectionView.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .automatic
        navigationItem.backButtonDisplayMode = .minimal
        let registration = UICollectionView.CellRegistration<ArtifactListCell, String> { [weak self] cell, _, id in
            guard let self, let row = self.byID[id] else { return }
            self.configure(cell, row: row)
        }
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { collection, indexPath, id in
            collection.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        apply(rows)
    }

    func configure(_ cell: UICollectionViewListCell, row: ArchiveRow) {
        var configuration = cell.defaultContentConfiguration()
        configuration.text = row.title
        configuration.secondaryText = row.subtitle
        configuration.textProperties.numberOfLines = 0
        configuration.secondaryTextProperties.numberOfLines = 0
        configuration.secondaryTextProperties.color = .archiveSecondaryLabel
        configuration.image = row.symbol.flatMap { UIImage(systemName: $0) }
        if row.artworkIdentifier != nil {
            configuration.textProperties.font = .preferredFont(forTextStyle: .headline)
            configuration.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
            configuration.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 16)
            configuration.image = UIImage(systemName: row.mediaType.artworkSymbol)
            configuration.imageProperties.tintColor = .tertiaryLabel
            configuration.imageProperties.reservedLayoutSize = CGSize(width: 72, height: 80)
            configuration.imageProperties.maximumSize = CGSize(width: 72, height: 80)
            configuration.imageProperties.cornerRadius = 3
        }
        cell.contentConfiguration = configuration
        (cell as? ArtifactListCell)?.setArtwork(identifier: row.artworkIdentifier)
        cell.accessories = row.navigates ? [.disclosureIndicator()] : []
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = [row.title, row.subtitle].compactMap { $0 }.joined(separator: ". ")
        cell.accessibilityTraits = row.navigates ? .button : .staticText
        cell.accessibilityIdentifier = row.id
    }

    func apply(_ newRows: [ArchiveRow]) {
        var seen = Set<String>()
        let uniqueRows = newRows.filter { seen.insert($0.id).inserted }
        if hasSnapshot, rows.map(\.id) == uniqueRows.map(\.id) {
            updateRows(uniqueRows)
            return
        }
        let anchor = visibleScrollAnchor()
        let previousRows = byID
        rows = uniqueRows
        byID = Dictionary(uniqueKeysWithValues: uniqueRows.map { ($0.id, $0) })
        rowIndices = Dictionary(uniqueKeysWithValues: uniqueRows.enumerated().map { ($0.element.id, $0.offset) })
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(uniqueRows.map(\.id))
        snapshot.reconfigureItems(uniqueRows.filter { previousRows[$0.id] != nil && previousRows[$0.id] != $0 }.map(\.id))
        snapshotGeneration += 1
        let generation = snapshotGeneration
        hasSnapshot = true
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self, self.snapshotGeneration == generation, let anchor else { return }
            self.restoreScrollAnchor(anchor)
        }
    }

    private func visibleScrollAnchor() -> (id: String, relativeY: CGFloat)? {
        guard dataSource != nil, collectionView.window != nil, !collectionView.isDragging, !collectionView.isDecelerating,
              let index = collectionView.indexPathsForVisibleItems.sorted().first,
              let id = dataSource.itemIdentifier(for: index),
              let attributes = collectionView.layoutAttributesForItem(at: index) else { return nil }
        return (id, attributes.frame.minY - collectionView.contentOffset.y)
    }

    private func restoreScrollAnchor(_ anchor: (id: String, relativeY: CGFloat)) {
        guard collectionView.window != nil, !collectionView.isDragging, !collectionView.isDecelerating,
              let index = dataSource.indexPath(for: anchor.id) else { return }
        collectionView.layoutIfNeeded()
        guard let attributes = collectionView.layoutAttributesForItem(at: index) else { return }
        let minimum = -collectionView.adjustedContentInset.top
        let maximum = max(minimum, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        let target = min(maximum, max(minimum, attributes.frame.minY - anchor.relativeY))
        if abs(target - collectionView.contentOffset.y) > 0.5 {
            collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
        }
    }

    /// Content-only changes reuse the identity snapshot and reconfigure only affected rows.
    func updateRows(_ changedRows: [ArchiveRow]) {
        var changedIndices = Set<Int>()
        for row in changedRows {
            guard let index = rowIndices[row.id], byID[row.id] != row else { continue }
            rows[index] = row
            byID[row.id] = row
            changedIndices.insert(index)
        }
        reconfigureRows(changedIndices.sorted().map { rows[$0].id })
    }

    func refreshRow(_ id: String) {
        reconfigureRows([id])
    }

    private func reconfigureRows(_ identifiers: [String]) {
        guard dataSource != nil, !identifiers.isEmpty else { return }
        let existing = identifiers.filter { dataSource.indexPath(for: $0) != nil }
        guard !existing.isEmpty else { return }
        // A diffable data source must own reconfiguration; calling the collection view's
        // reconfigureItems directly bypasses its update transaction and asserts on-device.
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(existing)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        selected(id)
    }
    func selected(_ id: String) {}

    override func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? ArtifactListCell)?.loadArtwork()
    }

    override func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? ArtifactListCell)?.cancelArtwork()
    }

    func showMessage(_ title: String, detail: String? = nil, retry: (() -> Void)? = nil) {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.text = title
        configuration.secondaryText = detail
        if let retry {
            configuration.button = .bordered()
            configuration.button.title = "Try Again"
            configuration.buttonProperties.primaryAction = UIAction { _ in retry() }
        }
        contentUnavailableConfiguration = configuration
    }

    func showLoading() { contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading() }
    func clearMessage() { contentUnavailableConfiguration = nil }

    func showError(_ error: Error) {
        let alert = UIAlertController(title: "Could not complete the change", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

/// Image work follows cell visibility and is guarded by identity across reuse.
@MainActor
private final class ArtifactListCell: UICollectionViewListCell {
    private var identifier: String?
    private var task: Task<Void, Never>?
    private var loadedImage: UIImage?

    func setArtwork(identifier: String?) {
        if self.identifier != identifier {
            cancelArtwork()
            loadedImage = nil
            self.identifier = identifier
        }
        if let loadedImage { assign(loadedImage) }
        else if window != nil { loadArtwork() }
    }

    func loadArtwork() {
        guard let identifier, task == nil, loadedImage == nil else { return }
        let scale = traitCollection.displayScale
        task = Task { [weak self] in
            let image = try? await ArtworkPipeline.shared.image(url: ArchiveURLs.thumbnail(identifier: identifier), pointSize: CGSize(width: 72, height: 80), scale: scale)
            guard !Task.isCancelled, let self, self.identifier == identifier else { return }
            self.task = nil
            self.loadedImage = image?.value
            if let image { self.assign(image.value) }
        }
    }

    private func assign(_ image: UIImage) {
        guard var configuration = contentConfiguration as? UIListContentConfiguration else { return }
        configuration.image = image
        configuration.imageProperties.tintColor = nil
        contentConfiguration = configuration
    }

    func cancelArtwork() { task?.cancel(); task = nil }
    override func prepareForReuse() {
        super.prepareForReuse()
        cancelArtwork(); identifier = nil; loadedImage = nil
    }
}

extension MediaType {
    var artworkSymbol: String {
        switch self {
        case .audio: "waveform"
        case .movies: "film"
        case .texts: "book.closed"
        case .image: "photo"
        case .software: "desktopcomputer"
        case .collection: "square.stack"
        default: "archivebox"
        }
    }
}

extension ArchiveRow {
    static func artifact(_ artifact: ArtifactSummary, prefix: String = "") -> ArchiveRow {
        let creator = artifact.creators.prefix(2).joined(separator: ", ")
        let metadata = [artifact.date.map { String($0.prefix(10)) }, artifact.mediaType.title].compactMap { $0 }.joined(separator: " · ")
        return ArchiveRow(id: prefix + artifact.identifier, title: artifact.title,
                          subtitle: [creator.isEmpty ? nil : creator, metadata].compactMap { $0 }.joined(separator: "\n"),
                          artworkIdentifier: artifact.identifier, mediaType: artifact.mediaType)
    }
}

extension ArtifactSummary {
    var rowSubtitle: String {
        (creators.prefix(2) + [date, mediaType.title].compactMap { $0 }).joined(separator: " · ")
    }
}

func archiveMessage(_ error: Error) -> String {
    if let error = error as? ArchiveError { return error.userMessage }
    if let error = error as? URLError, error.code == .notConnectedToInternet {
        return "You’re offline. Saved artifacts and completed downloads remain on this device."
    }
    return "The Archive could not be reached. Try again."
}

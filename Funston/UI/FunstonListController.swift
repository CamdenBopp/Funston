import UIKit

struct FunstonRow: Hashable {
    let id: String
    let title: String
    var subtitle: String? = nil
    var navigates = true
    var symbol: String? = nil
    var artworkIdentifier: String? = nil
    var mediaType: MediaType = .unknown
}

@MainActor
class FunstonListController: UICollectionViewController {
    private(set) var rows: [FunstonRow] = []
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var byID: [String: FunstonRow] = [:]
    private var rowIndices: [String: Int] = [:]
    private var hasSnapshot = false
    private var snapshotGeneration = 0

    init(title: String, appearance: UICollectionLayoutListConfiguration.Appearance = .plain) {
        var configuration = UICollectionLayoutListConfiguration(appearance: appearance)
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        self.title = title
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let id = dataSource?.itemIdentifier(for: indexPath), let row = byID[id] else { return nil }
            return swipeActions(for: row)
        }
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout.list(using: configuration)
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

    func configure(_ cell: UICollectionViewListCell, row: FunstonRow) {
        var configuration = cell.defaultContentConfiguration()
        configuration.text = row.title
        configuration.secondaryText = row.subtitle
        configuration.textProperties.numberOfLines = 0
        configuration.secondaryTextProperties.numberOfLines = 0
        configuration.secondaryTextProperties.color = .funstonSecondaryLabel
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

    func swipeActions(for row: FunstonRow) -> UISwipeActionsConfiguration? { nil }
    func isRowVisible(id: String) -> Bool {
        guard let index = dataSource?.indexPath(for: id) else { return false }
        return collectionView.indexPathsForVisibleItems.contains(index)
    }

    func scrollToRow(id: String) {
        guard let index = dataSource.indexPath(for: id) else { return }
        collectionView.scrollToItem(at: index, at: .centeredVertically, animated: true)
    }

    func apply(_ newRows: [FunstonRow]) {
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
    func updateRows(_ changedRows: [FunstonRow]) {
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

extension FunstonRow {
    static func artifact(_ artifact: ArtifactSummary, prefix: String = "") -> FunstonRow {
        let creator = artifact.creators.prefix(2).joined(separator: ", ")
        let metadata = [artifact.displayDate, artifact.mediaType.title].compactMap { $0 }.joined(separator: " · ")
        return FunstonRow(id: prefix + artifact.identifier, title: artifact.title,
                          subtitle: [creator.isEmpty ? nil : creator, metadata].compactMap { $0 }.joined(separator: "\n"),
                          artworkIdentifier: artifact.identifier, mediaType: artifact.mediaType)
    }
}

extension ArtifactSummary {
    /// Internet Archive dates arrive as free text ("1950", "c. 1950", "1950-03")
    /// or as ISO timestamps ("2020-01-05T00:00:00Z"). A timestamp shows its
    /// calendar date; anything else shows as written.
    var displayDate: String? {
        guard let date else { return nil }
        if date.firstMatch(of: /^\d{4}-\d{2}-\d{2}T/) != nil { return String(date.prefix(10)) }
        return date
    }

    /// The first four-digit year, for places that only have room for one.
    var displayYear: String? {
        guard let date else { return nil }
        return date.firstMatch(of: /\d{4}/).map { String($0.output) } ?? date
    }

    /// What VoiceOver reads for a shelf tile: the same facts the tile shows, plus the media type.
    var spokenSummary: String {
        ([title] + creators.prefix(2) + [displayYear, mediaType.title].compactMap { $0 }).joined(separator: ", ")
    }
}

func archiveMessage(_ error: Error) -> String {
    if let error = error as? ArchiveError { return error.userMessage }
    if let error = error as? URLError, error.code == .notConnectedToInternet {
        return "You’re offline. Your library and downloads still work."
    }
    return "Could not reach Internet Archive. Try again."
}

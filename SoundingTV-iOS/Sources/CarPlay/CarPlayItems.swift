import CarPlay
import UIKit

@MainActor
final class CarPlayArtwork {
    static let perListLimit = 100

    var displayScale: CGFloat = 2

    private let cache = NSCache<NSString, UIImage>()
    private var placeholders: [String: UIImage] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let concurrency = 4

    init() {
        cache.countLimit = 400
    }

    func cachedImage(for url: URL?, size: CGSize, round: Bool = false) -> UIImage? {
        guard let url else { return nil }
        return cache.object(forKey: Self.key(url, size, round))
    }

    func image(for url: URL?, size: CGSize, round: Bool = false) async -> UIImage? {
        guard let url else { return nil }
        let key = Self.key(url, size, round)
        if let hit = cache.object(forKey: key) { return hit }
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        if let hit = cache.object(forKey: key) { return hit }
        guard let cgImage = await SCArtworkStore.shared.cgImage(for: url, variant: .thumbnail) else { return nil }
        let scale = displayScale
        let rendered = await Task.detached(priority: .utility) {
            Self.render(cgImage, size: size, scale: scale, round: round)
        }.value
        cache.setObject(rendered, forKey: key)
        return rendered
    }

    func placeholder(symbol: String, size: CGSize) -> UIImage {
        let key = "\(symbol)#\(Int(size.width))x\(Int(size.height))"
        if let hit = placeholders[key] { return hit }
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIColor.systemGray4.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: min(size.width, size.height) * 0.12).fill()
            let configuration = UIImage.SymbolConfiguration(pointSize: min(size.width, size.height) * 0.4, weight: .regular)
            if let glyph = UIImage(systemName: symbol, withConfiguration: configuration)?
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal) {
                let origin = CGPoint(x: (size.width - glyph.size.width) / 2, y: (size.height - glyph.size.height) / 2)
                glyph.draw(at: origin)
            }
        }
        placeholders[key] = image
        return image
    }

    private static func key(_ url: URL, _ size: CGSize, _ round: Bool) -> NSString {
        "\(url.absoluteString)#\(Int(size.width))x\(Int(size.height))#\(round)" as NSString
    }

    private func acquire() async {
        if running < concurrency {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    nonisolated private static func render(_ cgImage: CGImage, size: CGSize, scale: CGFloat, round: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            if round {
                UIBezierPath(ovalIn: rect).addClip()
            }
            let source = CGSize(width: cgImage.width, height: cgImage.height)
            let fill = max(size.width / max(source.width, 1), size.height / max(source.height, 1))
            let drawn = CGSize(width: source.width * fill, height: source.height * fill)
            let origin = CGPoint(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2)
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: origin, size: drawn))
        }
    }
}

@MainActor
final class CarPlayPagedList {
    struct Page {
        let items: [CPListItem]
        let consumed: Int
    }

    typealias Loader = @MainActor (_ offset: Int, _ limit: Int) async -> Page

    weak var template: CPListTemplate?

    private let leading: [CPListItem]
    private let loader: Loader
    private let pageSize: Int
    private let emptyTitle: String
    private let emptySubtitle: String?
    private var items: [CPListItem] = []
    private var offset = 0
    private var hasMore = true
    private var task: Task<Void, Never>?
    private var pending: CPListTemplate?
    private lazy var moreItem: CPListItem = {
        let item = CPListItem(text: "Show More", detailText: nil)
        item.handler = { [weak self] _, completion in
            MainActor.assumeIsolated { self?.loadNext() }
            completion()
        }
        return item
    }()

    init(
        title: String,
        leading: [CPListItem] = [],
        pageSize: Int = 50,
        emptyTitle: String,
        emptySubtitle: String? = nil,
        loader: @escaping Loader
    ) {
        self.leading = leading
        self.loader = loader
        self.pageSize = pageSize
        self.emptyTitle = emptyTitle
        self.emptySubtitle = emptySubtitle
        let template = CPListTemplate(title: title, sections: [])
        template.showsSpinnerWhileEmpty = true
        template.userInfo = self
        self.template = template
        pending = template
    }

    func start() -> CPListTemplate {
        let template = pending ?? CPListTemplate(title: nil, sections: [])
        pending = nil
        loadNext()
        return template
    }

    private var capacity: Int {
        max(1, Int(CPListTemplate.maximumItemCount) - leading.count - 1)
    }

    private func loadNext() {
        guard task == nil, hasMore else { return }
        let room = capacity - items.count
        guard room > 0 else {
            hasMore = false
            publish()
            return
        }
        let limit = min(pageSize, room)
        let start = offset
        task = Task { [weak self] in
            guard let self else { return }
            let page = await self.loader(start, limit)
            guard !Task.isCancelled else { return }
            self.task = nil
            self.offset = start + page.consumed
            self.items += page.items.prefix(room)
            self.hasMore = page.consumed >= limit && self.items.count < self.capacity
            self.publish()
        }
    }

    private func publish() {
        guard let template else { return }
        var rows = leading + items
        if hasMore { rows.append(moreItem) }
        let hasContent = !items.isEmpty
        template.showsSpinnerWhileEmpty = false
        template.emptyViewTitleVariants = [emptyTitle]
        template.emptyViewSubtitleVariants = emptySubtitle.map { [$0] } ?? []
        template.updateSections(hasContent ? [CPListSection(items: rows)] : [])
    }
}

enum CarPlaySymbol {
    static func image(_ name: String) -> UIImage {
        UIImage(systemName: name) ?? UIImage()
    }
}

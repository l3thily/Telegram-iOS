import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TelegramPresentationData
import TelegramStringFormatting
import ChatHistoryScrollMapNode
import ChatControllerInteraction

// Drives the scroll map of a long chat: loads a coarse overview of the whole history and the
// mentions of and replies to the user, keeps the thumb in sync with the visible messages, shows the map
// while the history scrolls and hides it 1.5 s after scrolling stops.
final class ChatHistoryScrollMapController {
    static let minimumMessageCount: Int32 = 200

    // The overview takes 48 history requests, which can take several seconds; reopening a chat shows
    // the last one at once and refreshes it in the background.
    private struct CachedData {
        let overview: EngineMessageHistoryOverview
        let mentions: [EngineMessageHistoryMention]
        let timestamp: TimeInterval
    }
    private static var cache: [String: CachedData] = [:]
    private static let hideDelay: Double = 1.5

    private weak var chatController: ChatControllerImpl?
    private let context: AccountContext
    private let peerId: EnginePeer.Id
    let node: ChatHistoryScrollMapNode

    private var overview: EngineMessageHistoryOverview?
    private var dataDisposable: Disposable?
    private var visibleRangeDisposable: Disposable?
    private var scrollingDisposable: Disposable?
    private var isInteractivelyScrolling = false
    private var navigationDisposable = MetaDisposable()
    private var hideTimer: SwiftSignalKit.Timer?
    private var visibleRange: ChatTopVisibleMessageRange?

    var isEnabled: Bool {
        return (self.overview?.totalCount ?? 0) >= ChatHistoryScrollMapController.minimumMessageCount
    }

    init(context: AccountContext, peerId: EnginePeer.Id, chatController: ChatControllerImpl) {
        self.context = context
        self.peerId = peerId
        self.chatController = chatController
        self.node = ChatHistoryScrollMapNode()

        self.node.dateForPosition = { [weak self] position in
            return self?.dateString(at: position)
        }
        self.node.scrollToPosition = { [weak self] position in
            self?.scroll(to: position)
        }
        self.node.openMessage = { [weak self] messageId in
            self?.chatController?.navigateToMessage(from: nil, to: .id(messageId, NavigateToMessageParams(timestamp: nil, quote: nil)), forceInCurrentChat: true)
        }
        self.node.isInteractingUpdated = { [weak self] isInteracting in
            guard let self else {
                return
            }
            if isInteracting {
                self.hideTimer?.invalidate()
                self.hideTimer = nil
            } else {
                self.scheduleHide()
            }
        }

        let cacheKey = "\(context.account.id.int64):\(peerId.toInt64())"
        if let cached = ChatHistoryScrollMapController.cache[cacheKey], Date().timeIntervalSince1970 - cached.timestamp < 300.0 {
            self.overview = cached.overview
            self.updateContent(overview: cached.overview, mentions: cached.mentions)
        }

        self.dataDisposable = (combineLatest(queue: .mainQueue(),
            context.engine.messages.messageHistoryOverview(peerId: peerId),
            context.engine.messages.messageHistoryMentions(peerId: peerId)
        )
        |> deliverOnMainQueue).startStrict(next: { [weak self] overview, mentions in
            guard let self, let overview else {
                return
            }
            ChatHistoryScrollMapController.cache[cacheKey] = CachedData(overview: overview, mentions: mentions, timestamp: Date().timeIntervalSince1970)
            // Retain only a small, recent set of chats for the lifetime of this process.
            if ChatHistoryScrollMapController.cache.count > 16, let oldestKey = ChatHistoryScrollMapController.cache.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
                ChatHistoryScrollMapController.cache.removeValue(forKey: oldestKey)
            }
            self.overview = overview
            self.updateContent(overview: overview, mentions: mentions)
        })
    }

    deinit {
        self.dataDisposable?.dispose()
        self.visibleRangeDisposable?.dispose()
        self.scrollingDisposable?.dispose()
        self.navigationDisposable.dispose()
        self.hideTimer?.invalidate()
    }

    func attach(historyNode: ChatHistoryListNodeImpl) {
        self.visibleRangeDisposable?.dispose()
        self.visibleRangeDisposable = (historyNode.topVisibleMessageRange.get()
        |> deliverOnMainQueue).startStrict(next: { [weak self] range in
            guard let self else {
                return
            }
            self.visibleRange = range
            self.updateThumb()
            if self.isInteractivelyScrolling {
                self.historyDidScroll()
            }
        })
        // The CoreList backend never calls didScrollWithOffset, so the map follows the user's drag
        // (and the deceleration after it) instead: from the first touch until the list comes to rest.
        self.scrollingDisposable?.dispose()
        self.scrollingDisposable = (historyNode.isInteractivelyScrolling
        |> deliverOnMainQueue).startStrict(next: { [weak self] isScrolling in
            guard let self else {
                return
            }
            self.isInteractivelyScrolling = isScrolling
            if isScrolling {
                self.historyDidScroll()
            }
        })
    }

    // MARK: - Mapping

    // History position (0 = newest) of a message id, interpolated between the overview samples.
    private func historyPosition(of id: EngineMessage.Id) -> CGFloat? {
        guard let samples = self.overview?.samples, let first = samples.first else {
            return nil
        }
        if id.id >= first.id.id {
            return 0.0
        }
        for (upper, lower) in zip(samples, samples.dropFirst()) where id.id <= upper.id.id && id.id >= lower.id.id {
            let span = CGFloat(upper.id.id - lower.id.id)
            let t = span > 0.0 ? CGFloat(upper.id.id - id.id) / span : 0.0
            return CGFloat(upper.position) + t * CGFloat(lower.position - upper.position)
        }
        return CGFloat(samples.last?.position ?? 0)
    }

    // Fraction along the map: 0 is the oldest message (top), 1 the newest (bottom).
    private func mapPosition(of id: EngineMessage.Id) -> CGFloat? {
        guard let overview = self.overview, overview.totalCount > 1, let position = self.historyPosition(of: id) else {
            return nil
        }
        return 1.0 - position / CGFloat(overview.totalCount - 1)
    }

    private func timestamp(at mapPosition: CGFloat) -> Int32? {
        guard let overview = self.overview, let first = overview.samples.first else {
            return nil
        }
        let position = (1.0 - mapPosition) * CGFloat(max(0, overview.totalCount - 1))
        for (upper, lower) in zip(overview.samples, overview.samples.dropFirst()) where position >= CGFloat(upper.position) && position <= CGFloat(lower.position) {
            let span = CGFloat(lower.position - upper.position)
            let t = span > 0.0 ? (position - CGFloat(upper.position)) / span : 0.0
            return Int32(CGFloat(upper.timestamp) + t * CGFloat(lower.timestamp - upper.timestamp))
        }
        return position <= 0.0 ? first.timestamp : overview.samples.last?.timestamp
    }

    private func dateString(at position: CGFloat) -> String? {
        guard let timestamp = self.timestamp(at: position), let presentationData = self.chatController?.presentationData else {
            return nil
        }
        return humanReadableStringForTimestamp(strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat, timestamp: timestamp, alwaysShowTime: true).string
    }

    // MARK: - Content

    private func updateContent(overview: EngineMessageHistoryOverview, mentions: [EngineMessageHistoryMention]) {
        guard let presentationData = self.chatController?.presentationData else {
            return
        }

        // Messages per second between neighbouring samples, oldest segment first.
        var rates: [CGFloat] = []
        for (upper, lower) in zip(overview.samples, overview.samples.dropFirst()).reversed() {
            let count = CGFloat(lower.position - upper.position)
            let duration = CGFloat(max(1, upper.timestamp - lower.timestamp))
            rates.append(count / duration)
        }
        let maxRate = rates.max() ?? 0.0
        let density = rates.map { maxRate > 0.0 ? sqrt($0 / maxRate) : 0.0 }

        var marks: [ChatHistoryScrollMapNode.Mark] = []
        for mention in mentions {
            guard let position = self.mapPosition(of: mention.id) else {
                continue
            }
            marks.append(ChatHistoryScrollMapNode.Mark(kind: mention.isReply ? .reply : .mention, position: position, messageId: mention.id, isUnread: mention.isUnread))
        }

        var unreadPosition: CGFloat?
        if let maxReadIncomingId = overview.maxReadIncomingId, let first = overview.samples.first, maxReadIncomingId.id < first.id.id {
            unreadPosition = self.mapPosition(of: maxReadIncomingId)
        }

        self.node.update(theme: presentationData.theme, content: ChatHistoryScrollMapNode.Content(density: density, marks: marks, unreadPosition: unreadPosition))
        self.updateThumb()
    }

    private func updateThumb() {
        guard let overview = self.overview, overview.totalCount > 1, let range = self.visibleRange else {
            return
        }
        guard let newest = self.historyPosition(of: range.upperBound.id), let oldest = self.historyPosition(of: range.lowerBound.id) else {
            return
        }
        let total = CGFloat(overview.totalCount - 1)
        let center = 1.0 - (newest + oldest) * 0.5 / total
        let fraction = max(0.02, (oldest - newest + 1.0) / total)
        self.node.updateThumb(position: center, fraction: fraction, transition: .immediate)
    }

    // MARK: - Visibility

    func historyDidScroll() {
        guard self.isEnabled else {
            return
        }
        self.node.setShown(true, animated: true)
        self.updateThumb()
        self.scheduleHide()
    }

    private func scheduleHide() {
        self.hideTimer?.invalidate()
        if self.node.isInteracting {
            return
        }
        let timer = SwiftSignalKit.Timer(timeout: ChatHistoryScrollMapController.hideDelay, repeat: false, completion: { [weak self] in
            guard let self, !self.node.isInteracting else {
                return
            }
            self.node.setShown(false, animated: true)
        }, queue: Queue.mainQueue())
        self.hideTimer = timer
        timer.start()
    }

    private func scroll(to position: CGFloat) {
        guard let timestamp = self.timestamp(at: position) else {
            return
        }
        let peerId = self.peerId
        self.navigationDisposable.set((self.context.engine.messages.searchMessageIdByTimestamp(peerId: peerId, threadId: nil, timestamp: timestamp)
        |> deliverOnMainQueue).startStrict(next: { [weak self] messageId in
            guard let self, let messageId else {
                return
            }
            self.chatController?.navigateToMessage(from: nil, to: .id(messageId, NavigateToMessageParams(timestamp: nil, quote: nil)), forceInCurrentChat: true)
        }))
    }
}

extension ChatControllerImpl {
    func setupScrollMap(historyNode: ChatHistoryListNodeImpl) {
        guard case let .peer(peerId) = self.chatLocation, peerId.namespace != Namespaces.Peer.SecretChat, self.subject == nil, case .standard(.default) = self.presentationInterfaceState.mode else {
            self.scrollMapController = nil
            self.chatDisplayNode.scrollMapNode = nil
            return
        }
        if self.scrollMapController == nil {
            let scrollMapController = ChatHistoryScrollMapController(context: self.context, peerId: peerId, chatController: self)
            self.scrollMapController = scrollMapController
            self.chatDisplayNode.scrollMapNode = scrollMapController.node
        }
        self.scrollMapController?.attach(historyNode: historyNode)
    }
}

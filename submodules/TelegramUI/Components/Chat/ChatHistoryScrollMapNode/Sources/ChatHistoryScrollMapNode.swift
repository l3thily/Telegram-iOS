import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import TelegramPresentationData

// A thin map of the whole chat history along the right edge. Positions are fractions of the
// history: 0 is the oldest message (top), 1 the newest (bottom). The map shows how dense the
// conversation was, where the unread part starts and where the user was mentioned or replied to
// (unread ones brighter).
// Dragging the thumb shows the date under it and jumps there on release; tapping a mark opens
// that message.
public final class ChatHistoryScrollMapNode: ASDisplayNode, UIGestureRecognizerDelegate {
    public struct Mark: Equatable {
        public enum Kind: Equatable {
            case mention
            case reply
        }

        public let kind: Kind
        public let position: CGFloat
        public let messageId: EngineMessage.Id
        public let isUnread: Bool

        public init(kind: Kind, position: CGFloat, messageId: EngineMessage.Id, isUnread: Bool) {
            self.kind = kind
            self.position = position
            self.messageId = messageId
            self.isUnread = isUnread
        }
    }

    public struct Content: Equatable {
        // Messages per unit of time along the history, normalized to 0...1, oldest first.
        public let density: [CGFloat]
        public let marks: [Mark]
        public let unreadPosition: CGFloat?

        public init(density: [CGFloat], marks: [Mark], unreadPosition: CGFloat?) {
            self.density = density
            self.marks = marks
            self.unreadPosition = unreadPosition
        }
    }

    private static let trackWidth: CGFloat = 10.0
    private static let expandedTrackWidth: CGFloat = 16.0
    private static let markSize: CGFloat = 8.0
    private static let hitWidth: CGFloat = 44.0

    private let trackNode: ASDisplayNode
    private let densityNode: ASImageNode
    private let unreadLineNode: ASDisplayNode
    private var markNodes: [ASDisplayNode] = []
    private let thumbNode: ASDisplayNode
    private let dateBackgroundNode: ASDisplayNode
    private let dateTextNode: ImmediateTextNode
    private let hapticFeedback = HapticFeedback()

    private var theme: PresentationTheme?
    private var content: Content?
    private var size: CGSize?
    private var densityImageKey: (Content, CGSize, Bool)?
    private var thumbPosition: CGFloat = 1.0
    private var thumbFraction: CGFloat = 0.05
    private var dragPosition: CGFloat?

    public var dateForPosition: ((CGFloat) -> String?)?
    public var scrollToPosition: ((CGFloat) -> Void)?
    public var openMessage: ((EngineMessage.Id) -> Void)?
    public var isInteractingUpdated: ((Bool) -> Void)?

    public private(set) var isInteracting = false {
        didSet {
            if self.isInteracting != oldValue {
                self.isInteractingUpdated?(self.isInteracting)
            }
        }
    }

    public private(set) var isShown = false

    override public init() {
        self.trackNode = ASDisplayNode()
        self.trackNode.isLayerBacked = true
        self.trackNode.clipsToBounds = true

        self.densityNode = ASImageNode()
        self.densityNode.isLayerBacked = true
        self.densityNode.displaysAsynchronously = false

        self.unreadLineNode = ASDisplayNode()
        self.unreadLineNode.isLayerBacked = true

        self.thumbNode = ASDisplayNode()
        self.thumbNode.isLayerBacked = true

        self.dateBackgroundNode = ASDisplayNode()
        self.dateBackgroundNode.isLayerBacked = true
        self.dateBackgroundNode.alpha = 0.0

        self.dateTextNode = ImmediateTextNode()
        self.dateTextNode.displaysAsynchronously = false
        self.dateTextNode.alpha = 0.0

        super.init()

        self.alpha = 0.0
        self.addSubnode(self.trackNode)
        self.trackNode.addSubnode(self.densityNode)
        self.addSubnode(self.unreadLineNode)
        self.addSubnode(self.thumbNode)
        self.addSubnode(self.dateBackgroundNode)
        self.addSubnode(self.dateTextNode)
    }

    override public func didLoad() {
        super.didLoad()

        let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(self.panGesture(_:)))
        panRecognizer.delegate = self
        self.view.addGestureRecognizer(panRecognizer)

        let pressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(self.pressGesture(_:)))
        pressRecognizer.minimumPressDuration = 0.0
        pressRecognizer.delegate = self
        self.view.addGestureRecognizer(pressRecognizer)
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return gestureRecognizer.view === otherGestureRecognizer.view
    }

    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.isShown, let size = self.size, point.x >= size.width - ChatHistoryScrollMapNode.hitWidth, point.y >= -12.0, point.y <= size.height + 12.0 else {
            return nil
        }
        return self.view
    }

    // MARK: - Content

    public func update(theme: PresentationTheme, content: Content) {
        let themeUpdated = self.theme !== theme
        self.theme = theme
        if themeUpdated {
            let components = theme.chat.serviceMessage.components.withDefaultWallpaper
            self.trackNode.backgroundColor = components.dateFillFloating
            self.unreadLineNode.backgroundColor = components.primaryText
            self.thumbNode.backgroundColor = .white
            self.thumbNode.layer.shadowColor = UIColor.black.cgColor
            self.thumbNode.layer.shadowOpacity = 0.25
            self.thumbNode.layer.shadowRadius = 3.0
            self.thumbNode.layer.shadowOffset = CGSize(width: 0.0, height: 1.0)
            self.thumbNode.layer.borderColor = theme.list.itemAccentColor.cgColor
            self.thumbNode.layer.borderWidth = 2.0
            self.dateBackgroundNode.backgroundColor = components.dateFillFloating
        }
        if self.content != content || themeUpdated {
            self.content = content
            self.updateMarks()
            if let size = self.size {
                self.updateLayout(size: size, transition: .immediate)
            }
        }
    }

    private func color(for kind: Mark.Kind) -> UIColor {
        guard let theme = self.theme else {
            return .white
        }
        switch kind {
        case .mention:
            return theme.list.itemAccentColor
        case .reply:
            return UIColor(rgb: 0xff9f0a)
        }
    }

    private func updateMarks() {
        let marks = self.content?.marks ?? []
        while self.markNodes.count > marks.count {
            self.markNodes.removeLast().removeFromSupernode()
        }
        while self.markNodes.count < marks.count {
            let node = ASDisplayNode()
            node.isLayerBacked = true
            node.cornerRadius = ChatHistoryScrollMapNode.markSize * 0.5
            node.borderWidth = 1.5
            node.borderColor = UIColor.white.cgColor
            self.insertSubnode(node, belowSubnode: self.thumbNode)
            self.markNodes.append(node)
        }
        for (node, mark) in zip(self.markNodes, marks) {
            // Read ones stay on the map, quieter than the ones still waiting behind the @ button.
            node.backgroundColor = self.color(for: mark.kind).withAlphaComponent(mark.isUnread ? 1.0 : 0.55)
        }
    }

    // Density as a vertical strip: brighter where more messages were sent per minute.
    private func densityImage(size: CGSize, density: [CGFloat]) -> UIImage? {
        guard let theme = self.theme, !density.isEmpty, size.width > 0.0, size.height > 0.0 else {
            return nil
        }
        let accent = theme.list.itemAccentColor
        return generateImage(size, rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            let steps = Int(size.height)
            for step in 0 ..< steps {
                let position = CGFloat(step) / CGFloat(max(1, steps - 1)) * CGFloat(density.count - 1)
                let lower = Int(floor(position))
                let upper = min(density.count - 1, lower + 1)
                let t = position - CGFloat(lower)
                let value = density[lower] * (1.0 - t) + density[upper] * t
                context.setFillColor(accent.withAlphaComponent(0.12 + 0.78 * value).cgColor)
                context.fill(CGRect(x: 0.0, y: CGFloat(step), width: size.width, height: 1.0))
            }
        })
    }

    // MARK: - Layout

    private var trackRect: CGRect {
        guard let size = self.size else {
            return CGRect()
        }
        let width = self.isInteracting ? ChatHistoryScrollMapNode.expandedTrackWidth : ChatHistoryScrollMapNode.trackWidth
        return CGRect(x: size.width - 10.0 - width * 0.5 - ChatHistoryScrollMapNode.expandedTrackWidth * 0.5, y: 0.0, width: width, height: size.height)
    }

    private func y(for position: CGFloat) -> CGFloat {
        let rect = self.trackRect
        let inset: CGFloat = 4.0
        return rect.minY + inset + max(0.0, min(1.0, position)) * (rect.height - inset * 2.0)
    }

    private func position(for y: CGFloat) -> CGFloat {
        let rect = self.trackRect
        let inset: CGFloat = 4.0
        return max(0.0, min(1.0, (y - rect.minY - inset) / max(1.0, rect.height - inset * 2.0)))
    }

    public func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        self.size = size
        let trackRect = self.trackRect
        transition.updateFrame(node: self.trackNode, frame: trackRect)
        self.trackNode.cornerRadius = trackRect.width * 0.5

        let densityFrame = CGRect(origin: CGPoint(), size: trackRect.size)
        if let content = self.content {
            let key = (content, densityFrame.size, self.isInteracting)
            if self.densityImageKey.flatMap({ $0.0 != key.0 || $0.1 != key.1 }) ?? true {
                self.densityImageKey = key
                self.densityNode.image = self.densityImage(size: CGSize(width: ChatHistoryScrollMapNode.expandedTrackWidth, height: densityFrame.height), density: content.density)
            }
        }
        transition.updateFrame(node: self.densityNode, frame: densityFrame)

        if let unreadPosition = self.content?.unreadPosition {
            self.unreadLineNode.isHidden = false
            transition.updateFrame(node: self.unreadLineNode, frame: CGRect(x: trackRect.minX - 3.0, y: self.y(for: unreadPosition) - 1.0, width: trackRect.width + 6.0, height: 2.0))
            self.unreadLineNode.cornerRadius = 1.0
        } else {
            self.unreadLineNode.isHidden = true
        }

        let marks = self.content?.marks ?? []
        let markSize = self.isInteracting ? ChatHistoryScrollMapNode.markSize + 2.0 : ChatHistoryScrollMapNode.markSize
        for (node, mark) in zip(self.markNodes, marks) {
            node.cornerRadius = markSize * 0.5
            transition.updateFrame(node: node, frame: CGRect(x: trackRect.midX - markSize * 0.5, y: self.y(for: mark.position) - markSize * 0.5, width: markSize, height: markSize))
        }

        self.layoutThumb(transition: transition)
    }

    private func layoutThumb(transition: ContainedViewLayoutTransition) {
        guard self.size != nil else {
            return
        }
        let trackRect = self.trackRect
        let position = self.dragPosition ?? self.thumbPosition
        let height = max(22.0, min(trackRect.height * 0.3, trackRect.height * self.thumbFraction))
        let width = trackRect.width + 6.0
        let centerY = max(trackRect.minY + height * 0.5, min(trackRect.maxY - height * 0.5, self.y(for: position)))
        let thumbFrame = CGRect(x: trackRect.midX - width * 0.5, y: centerY - height * 0.5, width: width, height: height)
        transition.updateFrame(node: self.thumbNode, frame: thumbFrame)
        self.thumbNode.cornerRadius = width * 0.5

        if self.dragPosition != nil, let text = self.dateForPosition?(position), let theme = self.theme {
            self.dateTextNode.attributedText = NSAttributedString(string: text, font: Font.semibold(14.0), textColor: theme.chat.serviceMessage.components.withDefaultWallpaper.primaryText)
            let textSize = self.dateTextNode.updateLayout(CGSize(width: 240.0, height: 40.0))
            let backgroundSize = CGSize(width: textSize.width + 20.0, height: 30.0)
            let backgroundFrame = CGRect(x: thumbFrame.minX - 12.0 - backgroundSize.width, y: centerY - backgroundSize.height * 0.5, width: backgroundSize.width, height: backgroundSize.height)
            transition.updateFrame(node: self.dateBackgroundNode, frame: backgroundFrame)
            self.dateBackgroundNode.cornerRadius = backgroundSize.height * 0.5
            transition.updateFrame(node: self.dateTextNode, frame: CGRect(origin: CGPoint(x: backgroundFrame.minX + 10.0, y: backgroundFrame.minY + floor((backgroundSize.height - textSize.height) * 0.5)), size: textSize))
        }
    }

    // `position` is where the visible part of the history is centered, `fraction` how much of the
    // history fits on screen.
    public func updateThumb(position: CGFloat, fraction: CGFloat, transition: ContainedViewLayoutTransition) {
        self.thumbPosition = position
        self.thumbFraction = fraction
        if self.dragPosition == nil {
            self.layoutThumb(transition: transition)
        }
    }

    public func setShown(_ shown: Bool, animated: Bool) {
        if self.isShown == shown {
            return
        }
        self.isShown = shown
        let transition: ContainedViewLayoutTransition = animated ? .animated(duration: shown ? 0.2 : 0.35, curve: .easeInOut) : .immediate
        transition.updateAlpha(node: self, alpha: shown ? 1.0 : 0.0)
        if animated && shown {
            self.layer.animatePosition(from: CGPoint(x: 12.0, y: 0.0), to: CGPoint(), duration: 0.35, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
        }
    }

    // MARK: - Interaction

    private func setInteracting(_ value: Bool) {
        if self.isInteracting == value {
            return
        }
        self.isInteracting = value
        if value {
            self.hapticFeedback.impact(.light)
        }
        if let size = self.size {
            self.updateLayout(size: size, transition: .animated(duration: 0.25, curve: .spring))
        }
    }

    private func setDragPosition(_ position: CGFloat?) {
        let wasDragging = self.dragPosition != nil
        self.dragPosition = position
        let transition: ContainedViewLayoutTransition = .animated(duration: 0.2, curve: .easeInOut)
        if position != nil {
            self.layoutThumb(transition: .immediate)
            if !wasDragging {
                transition.updateAlpha(node: self.dateBackgroundNode, alpha: 1.0)
                transition.updateAlpha(node: self.dateTextNode, alpha: 1.0)
            }
        } else if wasDragging {
            transition.updateAlpha(node: self.dateBackgroundNode, alpha: 0.0)
            transition.updateAlpha(node: self.dateTextNode, alpha: 0.0)
        }
    }

    private func mark(at point: CGPoint) -> Mark? {
        var best: (Mark, CGFloat)?
        for mark in self.content?.marks ?? [] {
            let distance = abs(self.y(for: mark.position) - point.y)
            if distance < 14.0, distance < (best?.1 ?? .greatestFiniteMagnitude) {
                best = (mark, distance)
            }
        }
        return best?.0
    }

    @objc private func pressGesture(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            self.setInteracting(true)
        case .ended:
            let point = recognizer.location(in: self.view)
            if self.dragPosition == nil, let mark = self.mark(at: point) {
                self.hapticFeedback.tap()
                self.openMessage?(mark.messageId)
            }
            self.setInteracting(false)
        case .cancelled, .failed:
            if self.dragPosition == nil {
                self.setInteracting(false)
            }
        default:
            break
        }
    }

    @objc private func panGesture(_ recognizer: UIPanGestureRecognizer) {
        let position = self.position(for: recognizer.location(in: self.view).y)
        switch recognizer.state {
        case .began, .changed:
            self.setInteracting(true)
            if let previous = self.dragPosition, let content = self.content {
                // A light tick when the thumb crosses a mark.
                for mark in content.marks where (previous - mark.position) * (position - mark.position) < 0.0 {
                    self.hapticFeedback.tap()
                    break
                }
            }
            self.setDragPosition(position)
        case .ended:
            self.setDragPosition(nil)
            self.thumbPosition = position
            self.layoutThumb(transition: .immediate)
            self.scrollToPosition?(position)
            self.setInteracting(false)
        case .cancelled, .failed:
            self.setDragPosition(nil)
            self.layoutThumb(transition: .animated(duration: 0.25, curve: .spring))
            self.setInteracting(false)
        default:
            break
        }
    }
}

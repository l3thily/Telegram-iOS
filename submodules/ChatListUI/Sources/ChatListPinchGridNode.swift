import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import TelegramPresentationData
import AccountContext
import AvatarNode
import LocalizedPeerData

// Pinching the chat list turns it into a 4-column grid of avatars. The transition follows the
// fingers: `progress` 0 is the list, 1 is the grid, and every cell interpolates from the avatar of
// its row in the list to its place in the grid. Rows that are not on screen flow in from where they
// would be in the list.
final class ChatListPinchGridNode: ASDisplayNode, UIScrollViewDelegate {
    struct Item: Equatable {
        let peer: EnginePeer
        let unreadCount: Int32
        let isMuted: Bool
        let isOnline: Bool
    }

    private final class CellNode: ASDisplayNode {
        let avatarNode: AvatarNode
        let titleNode: ImmediateTextNode
        let badgeBackgroundNode: ASImageNode
        let badgeTextNode: ImmediateTextNode
        let onlineNode: ASImageNode
        var item: Item?

        override init() {
            self.avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 24.0))
            self.titleNode = ImmediateTextNode()
            self.titleNode.maximumNumberOfLines = 1
            self.titleNode.truncationType = .end
            self.titleNode.textAlignment = .center
            self.titleNode.displaysAsynchronously = false
            self.badgeBackgroundNode = ASImageNode()
            self.badgeBackgroundNode.displaysAsynchronously = false
            self.badgeTextNode = ImmediateTextNode()
            self.badgeTextNode.displaysAsynchronously = false
            self.onlineNode = ASImageNode()
            self.onlineNode.displaysAsynchronously = false

            super.init()

            self.addSubnode(self.avatarNode)
            self.addSubnode(self.titleNode)
            self.addSubnode(self.onlineNode)
            self.addSubnode(self.badgeBackgroundNode)
            self.addSubnode(self.badgeTextNode)
        }
    }

    static let columns = 4
    static let avatarSize: CGFloat = 62.0
    private static let rowHeight: CGFloat = 104.0

    private let context: AccountContext
    private let scrollNode: ASScrollNode
    private var cellNodes: [EnginePeer.Id: CellNode] = [:]
    private var items: [Item] = []
    private var presentationData: PresentationData
    private var size = CGSize()
    private var insets = UIEdgeInsets()
    // Avatar frames of the items in the list, in this node's coordinates.
    private var listFrames: [EnginePeer.Id: CGRect] = [:]

    private(set) var progress: CGFloat = 0.0
    private var displayLink: CADisplayLink?
    private var springTarget: CGFloat = 0.0
    private var springVelocity: CGFloat = 0.0
    private var springCompletion: (() -> Void)?

    var openPeer: ((EnginePeer) -> Void)?
    var progressUpdated: ((CGFloat) -> Void)?

    init(context: AccountContext, presentationData: PresentationData) {
        self.context = context
        self.presentationData = presentationData
        self.scrollNode = ASScrollNode()
        self.scrollNode.view.alwaysBounceVertical = true
        self.scrollNode.view.showsVerticalScrollIndicator = false
        self.scrollNode.view.contentInsetAdjustmentBehavior = .never

        super.init()

        self.addSubnode(self.scrollNode)
    }

    deinit {
        self.displayLink?.invalidate()
    }

    override func didLoad() {
        super.didLoad()

        self.scrollNode.view.delegate = self
        self.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:))))
    }

    // MARK: - Content

    func update(items: [Item], listFrames: [EnginePeer.Id: CGRect], size: CGSize, insets: UIEdgeInsets, presentationData: PresentationData) {
        let themeUpdated = self.presentationData.theme !== presentationData.theme
        self.presentationData = presentationData
        self.size = size
        self.insets = insets
        self.listFrames = listFrames

        var validIds = Set<EnginePeer.Id>()
        for item in items {
            validIds.insert(item.peer.id)
            let cellNode: CellNode
            if let current = self.cellNodes[item.peer.id] {
                cellNode = current
            } else {
                cellNode = CellNode()
                self.cellNodes[item.peer.id] = cellNode
                self.scrollNode.addSubnode(cellNode)
            }
            if cellNode.item != item || themeUpdated {
                cellNode.item = item
                self.configure(cellNode: cellNode, item: item)
            }
        }
        for (id, cellNode) in self.cellNodes where !validIds.contains(id) {
            cellNode.removeFromSupernode()
            self.cellNodes.removeValue(forKey: id)
        }
        self.items = items

        self.scrollNode.frame = CGRect(origin: CGPoint(), size: size)
        let rows = (items.count + ChatListPinchGridNode.columns - 1) / ChatListPinchGridNode.columns
        self.scrollNode.view.contentSize = CGSize(width: size.width, height: insets.top + CGFloat(rows) * ChatListPinchGridNode.rowHeight + insets.bottom + 12.0)
        self.layoutCells()
    }

    private func configure(cellNode: CellNode, item: Item) {
        let theme = self.presentationData.theme
        cellNode.avatarNode.setPeer(context: self.context, theme: theme, peer: item.peer, displayDimensions: CGSize(width: ChatListPinchGridNode.avatarSize, height: ChatListPinchGridNode.avatarSize))

        let title = item.peer.id == self.context.account.peerId ? self.presentationData.strings.DialogList_SavedMessages : item.peer.compactDisplayTitle
        cellNode.titleNode.attributedText = NSAttributedString(string: title, font: Font.medium(12.0), textColor: theme.chatList.titleColor)

        if item.unreadCount > 0 {
            let background = item.isMuted ? theme.chatList.unreadBadgeInactiveBackgroundColor : theme.chatList.unreadBadgeActiveBackgroundColor
            let textColor = item.isMuted ? theme.chatList.unreadBadgeInactiveTextColor : theme.chatList.unreadBadgeActiveTextColor
            cellNode.badgeTextNode.attributedText = NSAttributedString(string: compactNumericCountString(Int(item.unreadCount), decimalSeparator: self.presentationData.dateTimeFormat.decimalSeparator), font: Font.semibold(13.0), textColor: textColor)
            cellNode.badgeBackgroundNode.image = generateStretchableFilledCircleImage(diameter: 22.0, color: background, strokeColor: theme.chatList.backgroundColor, strokeWidth: 2.0)
            cellNode.badgeBackgroundNode.isHidden = false
            cellNode.badgeTextNode.isHidden = false
        } else {
            cellNode.badgeBackgroundNode.isHidden = true
            cellNode.badgeTextNode.isHidden = true
        }

        if item.isOnline {
            cellNode.onlineNode.image = generateFilledCircleImage(diameter: 16.0, color: theme.chatList.onlineDotColor, strokeColor: theme.chatList.backgroundColor, strokeWidth: 2.5)
            cellNode.onlineNode.isHidden = false
        } else {
            cellNode.onlineNode.isHidden = true
        }
    }

    // MARK: - Layout

    private func gridFrame(index: Int) -> CGRect {
        let columns = ChatListPinchGridNode.columns
        let cellWidth = floor((self.size.width - 16.0) / CGFloat(columns))
        let column = index % columns
        let row = index / columns
        let x = 8.0 + CGFloat(column) * cellWidth + floor((cellWidth - ChatListPinchGridNode.avatarSize) * 0.5)
        let y = self.insets.top + 10.0 + CGFloat(row) * ChatListPinchGridNode.rowHeight
        return CGRect(x: x, y: y, width: ChatListPinchGridNode.avatarSize, height: ChatListPinchGridNode.avatarSize)
    }

    // Where an item starts in the list: its row's avatar when on screen, otherwise where the row
    // would be if the list continued above or below the visible part.
    private func listFrame(index: Int, peerId: EnginePeer.Id) -> CGRect {
        if let frame = self.listFrames[peerId] {
            return frame
        }
        let known = self.items.enumerated().compactMap { offset, item -> (Int, CGRect)? in
            return self.listFrames[item.peer.id].map { (offset, $0) }
        }
        guard let first = known.first, let last = known.last else {
            return self.gridFrame(index: index).offsetBy(dx: 0.0, dy: self.size.height)
        }
        let rowHeight = known.count > 1 ? (last.1.minY - first.1.minY) / CGFloat(max(1, last.0 - first.0)) : 76.0
        let anchor = index < first.0 ? first : last
        return anchor.1.offsetBy(dx: 0.0, dy: CGFloat(index - anchor.0) * rowHeight)
    }

    private func layoutCells() {
        let p = self.progress
        let scrollOffset = self.scrollNode.view.contentOffset.y
        let detailsAlpha = max(0.0, min(1.0, (p - 0.55) / 0.45))
        let cellWidth = floor((self.size.width - 16.0) / CGFloat(ChatListPinchGridNode.columns))

        for (index, item) in self.items.enumerated() {
            guard let cellNode = self.cellNodes[item.peer.id] else {
                continue
            }
            // List frames are in screen space; the grid scrolls, so convert them into content space.
            let from = self.listFrame(index: index, peerId: item.peer.id).offsetBy(dx: 0.0, dy: scrollOffset)
            let to = self.gridFrame(index: index)
            let frame = CGRect(
                x: from.minX + (to.minX - from.minX) * p,
                y: from.minY + (to.minY - from.minY) * p,
                width: from.width + (to.width - from.width) * p,
                height: from.height + (to.height - from.height) * p
            )
            let avatarSize = ChatListPinchGridNode.avatarSize
            cellNode.frame = CGRect(x: frame.midX - cellWidth * 0.5, y: frame.minY, width: cellWidth, height: avatarSize + 24.0)
            let scale = frame.width / avatarSize
            cellNode.avatarNode.bounds = CGRect(origin: CGPoint(), size: CGSize(width: avatarSize, height: avatarSize))
            cellNode.avatarNode.position = CGPoint(x: cellWidth * 0.5, y: frame.height * 0.5)
            cellNode.avatarNode.transform = CATransform3DMakeScale(scale, scale, 1.0)
            // Rows that start off screen fade in as they flow into the grid.
            cellNode.alpha = self.listFrames[item.peer.id] == nil ? p : 1.0

            let titleSize = cellNode.titleNode.updateLayout(CGSize(width: cellWidth - 4.0, height: 20.0))
            cellNode.titleNode.frame = CGRect(x: floor((cellWidth - titleSize.width) * 0.5), y: avatarSize + 6.0, width: titleSize.width, height: titleSize.height)
            cellNode.titleNode.alpha = detailsAlpha

            let avatarFrame = CGRect(x: cellWidth * 0.5 - avatarSize * 0.5, y: 0.0, width: avatarSize, height: avatarSize)
            if !cellNode.badgeTextNode.isHidden {
                let textSize = cellNode.badgeTextNode.updateLayout(CGSize(width: 60.0, height: 22.0))
                let badgeWidth = max(22.0, textSize.width + 12.0)
                let badgeFrame = CGRect(x: avatarFrame.maxX - badgeWidth * 0.5 - 6.0, y: avatarFrame.minY - 2.0, width: badgeWidth, height: 22.0)
                cellNode.badgeBackgroundNode.frame = badgeFrame
                cellNode.badgeTextNode.frame = CGRect(x: badgeFrame.midX - textSize.width * 0.5, y: badgeFrame.midY - textSize.height * 0.5, width: textSize.width, height: textSize.height)
            }
            cellNode.badgeBackgroundNode.alpha = detailsAlpha
            cellNode.badgeTextNode.alpha = detailsAlpha
            cellNode.onlineNode.frame = CGRect(x: avatarFrame.maxX - 17.0, y: avatarFrame.maxY - 17.0, width: 16.0, height: 16.0)
            cellNode.onlineNode.alpha = detailsAlpha
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if self.progress >= 1.0 {
            self.layoutCells()
        }
    }

    // MARK: - Progress

    func setProgress(_ progress: CGFloat) {
        self.progress = progress
        self.scrollNode.view.isScrollEnabled = progress >= 1.0
        self.layoutCells()
        self.progressUpdated?(progress)
    }

    // A spring that overshoots slightly, so releasing the pinch settles with a small bounce.
    func animateProgress(to target: CGFloat, velocity: CGFloat, completion: (() -> Void)? = nil) {
        self.springTarget = target
        self.springVelocity = velocity
        self.springCompletion = completion
        if self.displayLink == nil {
            let displayLink = CADisplayLink(target: DisplayLinkTarget { [weak self] link in
                self?.springStep(link)
            }, selector: #selector(DisplayLinkTarget.event(_:)))
            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60.0, maximum: 120.0, preferred: 120.0)
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }
    }

    func stopAnimation() {
        self.displayLink?.invalidate()
        self.displayLink = nil
        self.springCompletion = nil
    }

    private func springStep(_ link: CADisplayLink) {
        let dt = CGFloat(min(1.0 / 30.0, max(1.0 / 240.0, link.targetTimestamp - link.timestamp)))
        let stiffness: CGFloat = 320.0
        let damping: CGFloat = 24.0
        let displacement = self.progress - self.springTarget
        let acceleration = -stiffness * displacement - damping * self.springVelocity
        self.springVelocity += acceleration * dt
        var progress = self.progress + self.springVelocity * dt
        if abs(progress - self.springTarget) < 0.001 && abs(self.springVelocity) < 0.01 {
            progress = self.springTarget
            self.displayLink?.invalidate()
            self.displayLink = nil
            self.setProgress(progress)
            let completion = self.springCompletion
            self.springCompletion = nil
            completion?()
            return
        }
        self.setProgress(progress)
    }

    // MARK: - Interaction

    @objc private func tapGesture(_ recognizer: UITapGestureRecognizer) {
        guard case .ended = recognizer.state, self.progress >= 1.0 else {
            return
        }
        let point = recognizer.location(in: self.scrollNode.view)
        for (index, item) in self.items.enumerated() {
            if self.gridFrame(index: index).insetBy(dx: -10.0, dy: -8.0).offsetBy(dx: 0.0, dy: 10.0).contains(point) {
                self.openPeer?(item.peer)
                return
            }
        }
    }
}

private final class DisplayLinkTarget: NSObject {
    private let f: (CADisplayLink) -> Void

    init(_ f: @escaping (CADisplayLink) -> Void) {
        self.f = f
    }

    @objc func event(_ link: CADisplayLink) {
        self.f(link)
    }
}

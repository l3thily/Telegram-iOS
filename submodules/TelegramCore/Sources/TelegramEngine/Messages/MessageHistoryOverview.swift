import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit

// A coarse picture of a whole chat history, for a scroll map: how many messages there are, which
// message sits at evenly spaced positions of the history and when it was sent, and where the read
// boundary is. Positions count from the newest message (0) towards the oldest (totalCount - 1).
public struct EngineMessageHistoryOverview: Equatable {
    public struct Sample: Equatable {
        public let position: Int32
        public let id: EngineMessage.Id
        public let timestamp: Int32

        public init(position: Int32, id: EngineMessage.Id, timestamp: Int32) {
            self.position = position
            self.id = id
            self.timestamp = timestamp
        }
    }

    public let totalCount: Int32
    // Ordered by position; the first sample is the newest message, the last one the oldest.
    public let samples: [Sample]
    public let maxReadIncomingId: EngineMessage.Id?

    public init(totalCount: Int32, samples: [Sample], maxReadIncomingId: EngineMessage.Id?) {
        self.totalCount = totalCount
        self.samples = samples
        self.maxReadIncomingId = maxReadIncomingId
    }
}

private func historyOverviewEntry(_ result: Api.messages.Messages, peerId: PeerId) -> (count: Int32, id: MessageId, timestamp: Int32)? {
    let count: Int32
    let messages: [Api.Message]
    switch result {
    case let .messages(data):
        count = Int32(data.messages.count)
        messages = data.messages
    case let .messagesSlice(data):
        count = data.count
        messages = data.messages
    case let .channelMessages(data):
        count = data.count
        messages = data.messages
    case .messagesNotModified:
        return nil
    }
    for message in messages {
        switch message {
        case let .message(data):
            return (count, MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: data.id), data.date)
        case let .messageService(data):
            return (count, MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: data.id), data.date)
        case .messageEmpty:
            continue
        }
    }
    return nil
}

func _internal_messageHistoryOverview(account: Account, peerId: PeerId, sampleCount: Int) -> Signal<EngineMessageHistoryOverview?, NoError> {
    let network = account.network
    return account.postbox.transaction { transaction -> (Api.InputPeer?, MessageId?) in
        var maxReadIncomingId: MessageId?
        if let readState = transaction.getCombinedPeerReadState(peerId) {
            for (namespace, state) in readState.states where namespace == Namespaces.Message.Cloud {
                if case let .idBased(maxIncomingReadId, _, _, _, _) = state {
                    maxReadIncomingId = MessageId(peerId: peerId, namespace: namespace, id: maxIncomingReadId)
                }
            }
        }
        return (transaction.getPeer(peerId).flatMap(apiInputPeer), maxReadIncomingId)
    }
    |> mapToSignal { inputPeer, maxReadIncomingId -> Signal<EngineMessageHistoryOverview?, NoError> in
        guard let inputPeer else {
            return .single(nil)
        }
        func sample(at position: Int32) -> Signal<(count: Int32, id: MessageId, timestamp: Int32)?, NoError> {
            return network.request(Api.functions.messages.getHistory(peer: inputPeer, offsetId: 0, offsetDate: 0, addOffset: position, limit: 1, maxId: 0, minId: 0, hash: 0))
            |> map { result -> (count: Int32, id: MessageId, timestamp: Int32)? in
                return historyOverviewEntry(result, peerId: peerId)
            }
            |> `catch` { _ -> Signal<(count: Int32, id: MessageId, timestamp: Int32)?, NoError> in
                return .single(nil)
            }
        }
        // The newest message tells how long the history is; the other samples are spread over it.
        return sample(at: 0)
        |> mapToSignal { newest -> Signal<EngineMessageHistoryOverview?, NoError> in
            guard let newest else {
                return .single(nil)
            }
            let lastPosition = max(0, newest.count - 1)
            let positions = (1 ..< max(2, sampleCount)).map { index -> Int32 in
                return Int32((Double(index) / Double(max(1, sampleCount - 1)) * Double(lastPosition)).rounded())
            }
            return combineLatest(positions.map { position in
                return sample(at: position)
                |> map { entry in
                    return entry.flatMap { EngineMessageHistoryOverview.Sample(position: position, id: $0.id, timestamp: $0.timestamp) }
                }
            })
            |> map { others -> EngineMessageHistoryOverview? in
                var samples = [EngineMessageHistoryOverview.Sample(position: 0, id: newest.id, timestamp: newest.timestamp)]
                for sample in others {
                    if let sample, sample.position > (samples.last?.position ?? -1) {
                        samples.append(sample)
                    }
                }
                return EngineMessageHistoryOverview(totalCount: newest.count, samples: samples, maxReadIncomingId: maxReadIncomingId)
            }
        }
    }
}

// Every message in a chat that mentions the user or replies to them (read or not), newest first, from
// the server's "my mentions" search. Unread ones are the ones still behind the @ button.
public struct EngineMessageHistoryMention: Equatable {
    public let id: EngineMessage.Id
    public let isReply: Bool
    public let isUnread: Bool

    public init(id: EngineMessage.Id, isReply: Bool, isUnread: Bool) {
        self.id = id
        self.isReply = isReply
        self.isUnread = isUnread
    }
}

func _internal_messageHistoryMentions(account: Account, peerId: PeerId, limit: Int32) -> Signal<[EngineMessageHistoryMention], NoError> {
    return account.postbox.transaction { transaction -> Api.InputPeer? in
        return transaction.getPeer(peerId).flatMap(apiInputPeer)
    }
    |> mapToSignal { inputPeer -> Signal<[EngineMessageHistoryMention], NoError> in
        guard let inputPeer else {
            return .single([])
        }
        return account.network.request(Api.functions.messages.search(flags: 0, peer: inputPeer, q: "", fromId: nil, savedPeerId: nil, savedReaction: nil, topMsgId: nil, filter: .inputMessagesFilterMyMentions, minDate: 0, maxDate: 0, offsetId: 0, addOffset: 0, limit: limit, maxId: 0, minId: 0, hash: 0))
        |> map { result -> [EngineMessageHistoryMention] in
            let messages: [Api.Message]
            switch result {
            case let .messages(data):
                messages = data.messages
            case let .messagesSlice(data):
                messages = data.messages
            case let .channelMessages(data):
                messages = data.messages
            case .messagesNotModified:
                messages = []
            }
            return messages.compactMap { message -> EngineMessageHistoryMention? in
                guard case let .message(data) = message else {
                    return nil
                }
                // A reply that does not also @mention the user is shown as a reply.
                let hasMentionEntity = (data.entities ?? []).contains(where: { entity in
                    switch entity {
                    case .messageEntityMention, .messageEntityMentionName, .inputMessageEntityMentionName:
                        return true
                    default:
                        return false
                    }
                })
                var isReply = false
                if case .messageReplyHeader? = data.replyTo {
                    isReply = !hasMentionEntity
                }
                let isUnread = (data.flags & (1 << 5)) != 0
                return EngineMessageHistoryMention(id: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: data.id), isReply: isReply, isUnread: isUnread)
            }
        }
        |> `catch` { _ -> Signal<[EngineMessageHistoryMention], NoError> in
            return .single([])
        }
    }
}

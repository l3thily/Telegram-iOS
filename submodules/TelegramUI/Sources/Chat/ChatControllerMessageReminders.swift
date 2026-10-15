import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TelegramPresentationData
import TelegramStringFormatting
import TextFormat
import UndoUI
import ContextUI
import ChatScheduleTimeController

// "Remind me later" is a scheduled forward of the message into Saved Messages. The server delivers
// it at the chosen time with a regular push, every device sees it, and the forward header leads
// back to the original message. A message has a reminder while such a forward is still scheduled.

private enum MessageReminderPreset {
    case inOneHour
    case thisEvening
    case tomorrow
}

private func messageReminderPresets(now: Int32) -> [(MessageReminderPreset, Int32)] {
    let calendar = Calendar.current
    let nowDate = Date(timeIntervalSince1970: Double(now))
    var result: [(MessageReminderPreset, Int32)] = []

    result.append((.inOneHour, (now + 60 * 60) / 60 * 60))

    if let evening = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: nowDate), evening.timeIntervalSince(nowDate) >= 60 * 60 {
        result.append((.thisEvening, Int32(evening.timeIntervalSince1970)))
    }

    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: nowDate), let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
        result.append((.tomorrow, Int32(morning.timeIntervalSince1970)))
    }
    return result
}

func messageReminderIds(view: MessageHistoryView, sourcePeerId: EnginePeer.Id) -> Set<EngineMessage.Id> {
    var result = Set<EngineMessage.Id>()
    for entry in view.entries {
        for attribute in entry.message.attributes {
            if let attribute = attribute as? SourceReferenceMessageAttribute, attribute.messageId.peerId == sourcePeerId {
                result.insert(attribute.messageId)
            }
        }
    }
    return result
}

private func scheduledSavedMessages(context: AccountContext) -> Signal<MessageHistoryView, NoError> {
    return context.account.viewTracker.scheduledMessagesViewForLocation(context.chatLocationInput(for: .peer(id: context.account.peerId), contextHolder: Atomic(value: nil)))
    |> map { view, _, _ -> MessageHistoryView in
        return view
    }
}

// The reminders (scheduled forwards in Saved Messages) that point at a message.
private func messageReminders(context: AccountContext, messageId: EngineMessage.Id) -> Signal<[Message], NoError> {
    return scheduledSavedMessages(context: context)
    |> take(1)
    |> map { view -> [Message] in
        return view.entries.map(\.message).filter { message in
            return message.attributes.contains(where: { ($0 as? SourceReferenceMessageAttribute)?.messageId == messageId })
        }
    }
}

extension ChatControllerImpl {
    func canSetMessageReminder(message: Message) -> Bool {
        guard case let .peer(peerId) = self.chatLocation, peerId != self.context.account.peerId else {
            return false
        }
        if case .scheduledMessages = self.presentationInterfaceState.subject {
            return false
        }
        if message.id.namespace != Namespaces.Message.Cloud || peerId.namespace == Namespaces.Peer.SecretChat {
            return false
        }
        if message.isCopyProtected() {
            return false
        }
        return true
    }

    func messageReminderContextMenuItems(messageId: EngineMessage.Id) -> Signal<[ContextMenuItem], NoError> {
        let presentationData = self.presentationData
        let strings = presentationData.strings
        return messageReminders(context: self.context, messageId: messageId)
        |> deliverOnMainQueue
        |> map { [weak self] reminders -> [ContextMenuItem] in
            var items: [ContextMenuItem] = []
            items.append(.action(ContextMenuActionItem(text: strings.Common_Back, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Back"), color: theme.actionSheet.primaryTextColor)
            }, iconPosition: .left, action: { c, _ in
                c?.popItems()
            })))
            items.append(.separator)

            let now = Int32(Date().timeIntervalSince1970)
            for (preset, timestamp) in messageReminderPresets(now: now) {
                let title: String
                switch preset {
                case .inOneHour:
                    title = strings.Conversation_RemindMe_InOneHour
                case .thisEvening:
                    title = strings.Conversation_RemindMe_ThisEvening
                case .tomorrow:
                    title = strings.Conversation_RemindMe_Tomorrow
                }
                // The title already says which day; the second line is just the time.
                items.append(.action(ContextMenuActionItem(text: title, textLayout: .secondLineWithValue(stringForMessageTimestamp(timestamp: timestamp, dateTimeFormat: presentationData.dateTimeFormat)), icon: { _ in
                    return nil
                }, action: { c, _ in
                    c?.dismiss(completion: {
                        self?.setMessageReminder(messageId: messageId, timestamp: timestamp)
                    })
                })))
            }
            items.append(.action(ContextMenuActionItem(text: strings.Conversation_RemindMe_Custom, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Schedule"), color: theme.actionSheet.primaryTextColor)
            }, action: { c, _ in
                c?.dismiss(completion: {
                    self?.presentMessageReminderTimePicker(messageId: messageId, currentTime: reminders.first.flatMap(\.timestamp))
                })
            })))

            if let current = reminders.first {
                items.append(.separator)
                items.append(.action(ContextMenuActionItem(text: strings.Conversation_RemindMe_Remove, textColor: .destructive, textLayout: .secondLineWithValue(messageReminderTimeString(presentationData: presentationData, timestamp: current.timestamp)), icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.actionSheet.destructiveActionTextColor)
                }, action: { c, _ in
                    c?.dismiss(completion: {
                        self?.removeMessageReminders(messageId: messageId)
                    })
                })))
            }
            return items
        }
    }

    private func presentMessageReminderTimePicker(messageId: EngineMessage.Id, currentTime: Int32?) {
        let controller = ChatScheduleTimeScreen(
            context: self.context,
            mode: .reminders,
            currentTime: currentTime,
            currentRepeatPeriod: nil,
            minimalTime: nil,
            silentPosting: false,
            isDark: false,
            completion: { [weak self] result in
                self?.setMessageReminder(messageId: messageId, timestamp: result.time)
            }
        )
        self.chatDisplayNode.dismissInput()
        self.push(controller)
    }

    func setMessageReminder(messageId: EngineMessage.Id, timestamp: Int32) {
        let context = self.context
        // One reminder per message: a new time replaces the scheduled forward instead of adding one.
        let _ = (messageReminders(context: context, messageId: messageId)
        |> mapToSignal { reminders -> Signal<Void, NoError> in
            if reminders.isEmpty {
                return .single(Void())
            }
            // The deletion completes without a value, so continue explicitly or the new forward is never sent.
            return context.engine.messages.deleteMessagesInteractively(messageIds: reminders.map(\.id), type: .forEveryone)
            |> then(.single(Void()))
        }
        |> mapToSignal { _ -> Signal<[MessageId?], NoError> in
            return enqueueMessages(account: context.account, peerId: context.account.peerId, messages: [
                .forward(source: messageId, threadId: nil, grouping: .none, attributes: [OutgoingScheduleInfoMessageAttribute(scheduleTime: timestamp, repeatPeriod: nil)], correlationId: nil)
            ])
        }).startStandalone()

        HapticFeedback().success()

        let presentationData = self.presentationData
        let text = presentationData.strings.Conversation_RemindMe_Set(messageReminderTimeString(presentationData: presentationData, timestamp: timestamp)).string
        self.present(UndoOverlayController(presentationData: presentationData, content: .universal(animation: "anim_set_notification", scale: 0.06, colors: [
            "Middle.Group 1.Fill 1": UIColor.white,
            "Top.Group 1.Fill 1": UIColor.white,
            "Bottom.Group 1.Fill 1": UIColor.white,
            "EXAMPLE.Group 1.Fill 1": UIColor.white,
            "Line.Group 1.Stroke 1": UIColor.white
        ], title: nil, text: text, customUndoText: presentationData.strings.Undo_Undo, timeout: nil), elevatedLayout: false, animateInAsReplacement: true, action: { [weak self] action in
            if case .undo = action {
                self?.removeMessageReminders(messageId: messageId, displayToast: false)
            }
            return false
        }), in: .current)
    }

    func removeMessageReminders(messageId: EngineMessage.Id, displayToast: Bool = true) {
        let context = self.context
        // Undo usually comes while the scheduled forward is still being sent: deleting the local copy then would
        // not cancel it on the server, so wait until every reminder for this message has its cloud id.
        let _ = (scheduledSavedMessages(context: context)
        |> map { view -> [Message] in
            return view.entries.map(\.message).filter { message in
                return message.attributes.contains(where: { ($0 as? SourceReferenceMessageAttribute)?.messageId == messageId })
            }
        }
        |> filter { reminders in
            return !reminders.isEmpty && reminders.allSatisfy { $0.id.namespace == Namespaces.Message.ScheduledCloud }
        }
        |> take(1)
        |> timeout(15.0, queue: .mainQueue(), alternate: .complete())
        |> mapToSignal { reminders -> Signal<Void, NoError> in
            return context.engine.messages.deleteMessagesInteractively(messageIds: reminders.map(\.id), type: .forEveryone)
        }).startStandalone()

        if displayToast {
            let presentationData = self.presentationData
            self.present(UndoOverlayController(presentationData: presentationData, content: .universal(animation: "anim_profileunmute", scale: 0.075, colors: [
                "Middle.Group 1.Fill 1": UIColor.white,
                "Top.Group 1.Fill 1": UIColor.white,
                "Bottom.Group 1.Fill 1": UIColor.white,
                "EXAMPLE.Group 1.Fill 1": UIColor.white,
                "Line.Group 1.Stroke 1": UIColor.white
            ], title: nil, text: presentationData.strings.Conversation_RemindMe_Removed, customUndoText: nil, timeout: nil), elevatedLayout: false, animateInAsReplacement: true, action: { _ in
                return false
            }), in: .current)
        }
    }
}

// "19:00" for today, "tomorrow at 9:00" and dates further away otherwise.
private func messageReminderTimeString(presentationData: PresentationData, timestamp: Int32) -> String {
    let calendar = Calendar.current
    let date = Date(timeIntervalSince1970: Double(timestamp))
    if calendar.isDateInToday(date) {
        return stringForMessageTimestamp(timestamp: timestamp, dateTimeFormat: presentationData.dateTimeFormat)
    }
    return humanReadableStringForTimestamp(strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat, timestamp: timestamp, alwaysShowTime: true).string
}

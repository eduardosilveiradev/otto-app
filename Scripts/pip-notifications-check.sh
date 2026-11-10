#!/bin/bash
# Exercise the conversation decoder, notification path and read clearing without an iOS host.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
python3 - "$T/check.swift" <<'PY'
import pathlib, re, sys

def method(source, name):
    start = re.search(r'^    (?:private )?(?:static )?func ' + re.escape(name) + r'\(', source, re.M).start()
    end = source.index('\n    }', start) + len('\n    }')
    return source[start:end].replace('private func', 'func')

pips = pathlib.Path('Otto/Pips.swift').read_text()
notifications = pathlib.Path('Otto/Notifications.swift').read_text()
parts = ['import Foundation', '''
struct PipButton: Codable, Sendable {}
struct GroupLink: Codable, Sendable {}
struct PipDetail: Decodable, Sendable {}
struct PipMember: Decodable, Sendable { var name = "Helper" }
struct PipHandoff: Decodable, Sendable {}
struct Message { var text = "Otto reply"; var thread: String?; var wireID = "otto-id"; var level: String? }
enum LiveBackend { static func date(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s) } }
struct Row { var name = "Conversation"; var isGroup = false }
struct Backend { var desktopSync: DesktopSync? }
struct Store { var backend: Backend }
final class UNMutableNotificationContent {
    var title = "", body = "", categoryIdentifier = "", threadIdentifier = ""
    var sound: Sound?; var userInfo: [String: String] = [:]; var relevanceScore = 0.0; var badge: NSNumber?
    enum Sound { case `default` }
}
struct UNNotificationRequest { let identifier: String; let content: UNMutableNotificationContent; let trigger: Int? }
struct Notification { let request: UNNotificationRequest }
final class UNUserNotificationCenter {
    static let shared = UNUserNotificationCenter()
    static func current() -> UNUserNotificationCenter { shared }
    var requests: [UNNotificationRequest] = []
    var delivered: [String] = [], pending: [String] = []
    func add(_ request: UNNotificationRequest) { requests.append(request) }
    func removeDeliveredNotifications(withIdentifiers ids: [String]) { delivered = ids }
    func removePendingNotificationRequests(withIdentifiers ids: [String]) { pending = ids }
    func getDeliveredNotifications(_ done: ([Notification]) -> Void) { done([]) }
    func setBadgeCount(_ count: Int) {}
}
''']
parts += [pips[pips.index('struct ConversationMessage:'):pips.index('\nstruct ConversationRow:')],
          pips[pips.index('enum ConversationEvent:'):pips.index('\nextension Message {')],
          pathlib.Path('Otto/DesktopSync.swift').read_text().split('    static func tapFrame')[0] + '}']
# DesktopSync's other model operations are covered by desktop-sync-check.sh.
parts[-1] = re.sub(r'        func apply\(to messages: inout \[Message\]\) \{.*?\n        \}', '', parts[-1], flags=re.S)
parts += ['''
final class Notifier {
    static let shared = Notifier()
    static let category = "OTTO_MESSAGE", pipCategory = "OTTO_PIP_MESSAGE", unreadKey = "pip-notification-check-" + UUID().uuidString
''', method(notifications, 'post'),
          method(notifications[notifications.index('    func post(title:'):], 'post'), method(notifications, 'clear'), '}', '''
final class Pips {
    var store: Store?
    var notifiedThrough = Date.distantPast
    var group = false
    func row(_ id: String) -> Row? { Row(isGroup: group) }
    func member(_ id: String) -> PipMember? { PipMember() }
''', method(pips, 'notify'), '}', '''
let key = "pip-notification-sync-" + UUID().uuidString
let sync = DesktopSync(key: key)
let pips = Pips()
pips.store = Store(backend: Backend(desktopSync: sync))
defer {
    UserDefaults.standard.removeObject(forKey: key)
    UserDefaults.standard.removeObject(forKey: Notifier.unreadKey)
}
func message(_ id: String, conversation: String = "pip-helper", kind: String = "text", quiet: Bool = false, sender: String = "helper") -> ConversationMessage {
    let data = try! JSONSerialization.data(withJSONObject: ["type": "conversation_message", "message": ["id": id, "conversation_id": conversation, "sender": sender, "kind": kind, "text": "Hello", "ts": "2026-01-01T12:00:00Z", "quiet": quiet]])
    guard case .message(let m) = ConversationEvent.decode(type: "conversation_message", data) else { fatalError("conversation decode") }
    return m
}
let center = UNUserNotificationCenter.current()
for group in [false, true] {
    pips.group = group
    pips.notifiedThrough = .distantPast
    let id = group ? "group-message" : "pip-message"
    let conversation = group ? "group-chat" : "pip-helper"
    pips.notify(message(id, conversation: conversation))
    let request = center.requests.last!
    assert(request.identifier == id)
    assert(request.content.userInfo["conversation"] == conversation)
    assert(request.content.sound != nil && request.content.categoryIdentifier == "OTTO_PIP_MESSAGE")
    assert(request.content.body == (group ? "Helper: Hello" : "Hello"))
    let count = center.requests.count
    pips.notifiedThrough = .distantPast
    pips.notify(message("quiet-" + id, conversation: conversation, quiet: true))
    assert(center.requests.count == count, "quiet matches Otto: no notification or sound")
}
let read = Data(#"{"type":"notifications_read","ids":["pip-message","group-message"]}"#.utf8)
assert(sync.receive(read))
let ids = sync.snapshot.notificationIDs(in: [])
Notifier.clear(ids)
assert(Set(center.pending) == ["pip-message", "group-message"])
assert(Set(center.delivered) == ["pip-message", "group-message"])
let count = center.requests.count
pips.notifiedThrough = .distantPast
pips.notify(message("pip-message"))
assert(center.requests.count == count, "read-before-message must stay cleared")
pips.notify(message("system-message", kind: "system"))
assert(center.requests.last!.identifier == "system-message")
Notifier.shared.post(Message())
assert(center.requests.last!.identifier == "otto-id")
assert(center.requests.last!.content.userInfo.isEmpty)
assert(center.requests.last!.content.sound != nil)
print("pip notification checks passed")
''']
# notificationIDs uses these fields even though the empty-history case is the point here.
parts[1] = parts[1].replace('var text = "Otto reply";', 'var id = UUID(); var text = "Otto reply";')
pathlib.Path(sys.argv[1]).write_text('\n'.join(parts))
PY
swift "$T/check.swift"

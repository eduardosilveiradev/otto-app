#!/bin/bash
# Run the real delivery/reconcile methods and wire decoder without an iOS test host.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
python3 - "$T/check.swift" <<'PY'
import pathlib, re, sys

def method(source, name):
    start = re.search(r'^    (?:private )?func ' + name + r'\(', source, re.M).start()
    end = source.index('\n    }', start) + len('\n    }')
    return source[start:end].replace('private func', 'func')

store = pathlib.Path('Otto/OttoApp.swift').read_text()
backend = pathlib.Path('Otto/Backend.swift').read_text()
live = pathlib.Path('Otto/LiveBackend.swift').read_text()
parts = ['import Foundation', backend[backend.index('enum Sender:'):backend.index('struct CalEvent:')]]
parts += ['''
struct DashTrigger: Codable {}
struct RecordedCard: Codable {}
struct OTPCode: Codable {}
struct Card: Codable { var actions: [ActionButton]? }
enum ImageStore { static func data(_ id: UUID) -> Data? { nil } }
enum VoiceStore { static var audio: Data? = Data([1]); static func data(_ id: UUID) -> Data? { audio } }
enum Notifier {
    static let shared = NotifierStub()
    static func clear(_ ids: [String]) {}
}
struct NotifierStub { func post(_ message: Message) {} }
@MainActor class FakeBackend {
    var rows: [Message] = []
    var response: String? = "transcript"
    var held: CheckedContinuation<String?, Never>?
    var hold = false
    var calls = 0
    var desktopSync: DesktopSync? = nil
    func history(background: Bool, limit: Int, since: Date?) async -> [Message]? { rows }
    func sendVoice(_ audio: Data, id: String, replyTo: String?) async -> String? {
        calls += 1
        if hold { return await withCheckedContinuation { held = $0 } }
        return response
    }
    func sendPhoto(_ audio: Data, caption: String, id: String, replyTo: String?, shared: Bool) async -> Bool { false }
    func tap(_ button: ActionButton, id: String, source: String?) async -> Bool { false }
    func wallet(_ wallet: [String: String], id: String) async -> Bool { false }
    func send(_ text: String, id: String, replyTo: String?, shared: Bool) async -> Bool { false }
}
@MainActor class MockBackend: FakeBackend {}
@MainActor class LiveBackend: FakeBackend {
    struct Answer {}
    func snap(_ audio: Data, note: String, id: String) async -> Answer? { nil }
    nonisolated static func date(_ s: String?) -> Date? { ISO8601DateFormatter().date(from: s ?? "") }
}
''', pathlib.Path('Otto/DesktopSync.swift').read_text(), '''
@MainActor final class Store {
    let backend: FakeBackend
    var messages: [Message] = []
    var foreground = true
    var ottoTyping = false
    var ottoStatus: String?
    var serverTyping = false
    var ottoTodos: [TodoItem] = []
    var syncCursor: Date?
    var sending: Set<UUID> = []
    var voiceReconcile: Task<Void, Never>?
    init(_ backend: FakeBackend) { self.backend = backend }
    func save() {}
    func armTypingTimeout() {}
''']
for name in ['deliver', 'deliverVoice', 'retry', 'resendPending', 'markUndelivered', 'catchUp', 'reconcileDesktop']:
    parts.append(method(store, name))
# Optional on the pre-fix revision, so the check demonstrates its missing activity recovery.
if 'func reconcileVoiceDelivery()' in store:
    parts.append(method(store, 'reconcileVoiceDelivery'))
else:
    parts.append('func reconcileVoiceDelivery() {}')
# Exercise the exact read-stream handler rather than a reimplementation.
start = store.index('            for await ids in backend.reads {')
end = store.index('\n        }', start)
parts.append('func read(_ ids: [String]) async {\n' + store[start:end].replace('for await ids in backend.reads', 'for ids in [ids]') + '\n}')
for stream, signature, loop in [
    ('statuses', 'status(_ text: String)', 'text in [text]'),
    ('todoLists', 'todos(_ items: [TodoItem])', 'items in [items]'),
    ('typing', 'typing(_ on: Bool)', 'on in [on]'),
    ('reactions', 'react(_ id: String, _ emoji: String)', '(id, emoji) in [(id, emoji)]'),
]:
    start = re.search(r'            for await .* in backend\.' + stream + r' \{', store).start()
    end = store.index('\n        }', start)
    body = re.sub(r'for await .* in backend\.' + stream, 'for ' + loop, store[start:end], count=1)
    parts.append('func ' + signature + ' async {\n' + body + '\n}')
parts.append('}')
# Decode history with the production mapper/types, feeding it fake HTTP rows.
wire_start = live.index('    private struct WireButton:')
wire_end = live.index('    private struct WireBrief:')
parts += ['''
final class HistoryDecoder {
    let payload: Data
    init(_ payload: Data) { self.payload = payload }
    func get<T: Decodable>(_ path: String, background: Bool, query: [URLQueryItem]) async -> T? {
        try? JSONDecoder().decode(T.self, from: payload)
    }
    static func date(_ s: String?) -> Date? { LiveBackend.date(s) }
    static func terminal(_ text: String, ts: String) -> Message { Message(from: .terminal, text: text) }
''', live[wire_start:wire_end], method(live, 'history'), '}']
parts += ['class VoiceDecoder { var response: Data?; func post(_ path: String, _ body: Data, query: [URLQueryItem]) async -> Data? { response }', method(live, 'sendVoice'), '}']
pathlib.Path(sys.argv[1]).write_text('\n'.join(parts) + '\n')
PY
cat >> "$T/check.swift" <<'SWIFT'
@main struct Check {
    @MainActor static func main() async {
        let decoder = VoiceDecoder()
        for body in [#"{"text":"spoken words"}"#, #"{"text":""}"#] {
            decoder.response = Data(body.utf8)
            let result = await decoder.sendVoice(Data([1]), id: "test-note", replyTo: nil)
            assert(result != nil) // both normal and deduped 2xx responses are delivery
        }
        decoder.response = nil
        let failed = await decoder.sendVoice(Data([1]), id: "test-note", replyTo: nil)
        assert(failed == nil)
        // The real server preserves this exact UUID in /app/history, including its casing.
        let note = Message(from: .me, text: "", isVoice: true, pending: true)
        let payload = try! JSONSerialization.data(withJSONObject: [["dir": "in", "text": "spoken words", "ts": "2026-01-01T12:00:00Z", "id": note.wireID]])
        let rows = await HistoryDecoder(payload).history(background: false, limit: 50, since: nil)
        assert(rows?.count == 1 && rows?[0].wireID == note.wireID)
        let backend = FakeBackend()
        let store = Store(backend)
        store.messages = [note]
        backend.hold = true
        let upload = Task { await store.deliver(note.id) }
        while backend.held == nil { await Task.yield() }
        // A reconnect/retry cannot start a second upload while this one is waiting.
        await store.resendPending()
        store.retry(note.id)
        await Task.yield()
        assert(backend.calls == 1 && store.sending.contains(note.id))
        // Unrelated activity/history must never acknowledge our note.
        backend.rows = [Message(from: .me, text: "other", serverID: "unrelated")]
        await store.status("Working")
        await store.voiceReconcile?.value
        assert(store.messages[0].pending == true)
        // Server thinking + matching history proves receipt BEFORE HTTP completes.
        backend.rows = rows
        await store.status("Working")
        await store.voiceReconcile?.value
        assert(store.messages[0].pending == nil, "server activity/history left voice note Sending")
        assert(store.messages[0].text == "spoken words")
        backend.held!.resume(returning: nil) // response lost after server acceptance
        await upload.value
        assert(store.messages[0].failed == nil && store.sending.isEmpty)
        // ID-matched read receipts alone are also proof; another id is not.
        store.messages = [note]
        await store.read(["unrelated"])
        assert(store.messages[0].pending == true)
        store.messages[0].failed = true
        await store.read([note.wireID])
        assert(store.messages[0].read == true && store.messages[0].pending == nil && store.messages[0].failed == nil)
        store.messages = [note]
        await store.react(note.wireID, "👍")
        assert(store.messages[0].pending == nil && store.messages[0].reaction == "👍")
        for signal in ["typing", "todos"] {
            store.messages = [note]
            if signal == "typing" { await store.typing(true) }
            else { await store.todos([TodoItem(text: "Working", status: .in_progress)]) }
            await store.voiceReconcile?.value
            assert(store.messages[0].pending == nil && store.messages[0].text == "spoken words")
        }
        // A dedupe's empty transcript must not erase one recovered from history.
        backend.hold = false
        backend.response = ""
        store.messages[0].pending = true
        store.messages[0].text = "spoken words"
        await store.deliver(note.id)
        assert(store.messages[0].text == "spoken words" && store.messages[0].pending == nil)
        // HTTP failure with a committed history row still means delivered.
        store.messages = [note]
        backend.response = nil
        await store.deliver(note.id)
        assert(store.messages[0].pending == nil && store.messages[0].failed == nil)
        // Real failure keeps its audio and stable id for retry, and shows Not delivered.
        backend.rows = []
        store.messages = [note]
        await store.deliver(note.id)
        assert(store.messages[0].pending == true && store.messages[0].failed == true)
        backend.response = "retried words"
        store.retry(note.id)
        while store.messages[0].pending == true { await Task.yield() }
        assert(store.messages[0].failed == nil && store.messages[0].wireID == note.wireID)
        // Missing audio cannot be uploaded or offered as delivered.
        VoiceStore.audio = nil
        store.messages = [note]
        await store.deliver(note.id)
        assert(store.messages[0].failed == true && store.messages[0].pending == nil)
        print("voice delivery checks passed")
    }
}
SWIFT
swiftc -parse-as-library "$T/check.swift" -o "$T/check"
"$T/check"

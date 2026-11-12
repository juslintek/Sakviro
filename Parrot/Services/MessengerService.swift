import Foundation
import AppKit

struct MessengerChat: Decodable, Identifiable {
    let id: String
    let title: String
    let source: String?
    let mode: String?
    let is_group: Bool?

    var isLive: Bool { source == "meta" }
}

struct MessengerMessage: Decodable, Identifiable {
    let id: String
    let sender: String
    let text: String
    let timestamp: String?
    let outgoing: Bool?
}

struct MessengerDraft: Decodable, Identifiable {
    let id: String
    let chat_id: String
    let text: String
    let state: String
    let version: Int

    var canApprove: Bool { state == "draft" }
    var statusText: String {
        switch state {
        case "accepted": return "Accepted by Meta. Delivery is unconfirmed."
        case "uncertain": return "Send outcome is uncertain. Check Messenger before sending again."
        case "stale": return "Conversation changed. Review the reply again."
        default: return state.capitalized
        }
    }
}

struct MessengerHistory: Decodable {
    let chat: MessengerChat
    let messages: [MessengerMessage]
    let drafts: [MessengerDraft]?
    let next_before: String?
    let style: MessengerStyle?
}

struct MessengerStyle: Decodable {
    struct Profile: Decodable {
        let sample_count: Int?
        let median_characters: Double?
    }
    struct Example: Decodable, Identifiable {
        let text: String
        var id: String { text }
    }
    let profile: Profile?
    let examples: [Example]?
}

struct MessengerStatus: Decodable {
    struct Meta: Decodable { let connected: Bool; let error: String? }
    let meta: Meta
}

private final class MessengerRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
@Observable
final class MessengerService {
    private(set) var chats: [MessengerChat] = []
    private(set) var history: MessengerHistory?
    private(set) var messages: [MessengerMessage] = []
    private(set) var draft: MessengerDraft?
    private(set) var connected = false
    private(set) var connectionStatus = "Start MessengerDesk, then paste its connection token."
    private(set) var isBusy = false
    private(set) var error: String?
    private var token = ""
    private static let keyAccount = "messengerdesk-access-token"
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 150
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: MessengerRedirectPolicy(), delegateQueue: nil)
    }

    nonisolated static func request(path: String, token: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard path.hasPrefix("/api/"), !path.contains("#"), !token.isEmpty,
              !token.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = URL(string: "http://127.0.0.1:8766" + path),
              url.host == "127.0.0.1", url.port == 8766 else {
            throw MessengerError("Enter the MessengerDesk connection token.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    nonisolated static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
    }

    func restore() async {
        if let saved = await APIKeyStore.loadInBackground(account: Self.keyAccount) {
            await connect(saved, save: false)
        } else {
            let tokenURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/MessengerDesk/access-token")
            guard let localToken = try? String(contentsOf: tokenURL, encoding: .utf8) else { return }
            await connect(localToken)
        }
    }

    func connect(_ entered: String, save: Bool = true) async {
        await run {
            self.token = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            let status: MessengerStatus = try await self.fetch("/api/status")
            if save, !APIKeyStore.save(self.token, account: Self.keyAccount) {
                throw MessengerError("macOS could not save the connection token in Keychain.")
            }
            self.connected = true
            self.connectionStatus = status.meta.connected ? "MessengerDesk connected. Meta is available." : "MessengerDesk connected. Sign in to Meta in the native MessengerDesk app."
            try await self.loadChats()
        }
    }

    func openMessengerDesk() {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.linas.messengerdesk") else {
            error = "Open the native MessengerDesk app, then connect here."
            return
        }
        NSWorkspace.shared.open(application)
    }

    func refreshChats() async { await run { try await self.loadChats() } }

    func select(_ chat: MessengerChat) async {
        await run {
            let history: MessengerHistory = try await self.fetch("/api/chats/" + Self.encode(chat.id))
            self.history = history
            self.messages = history.messages
            self.draft = history.drafts?.first(where: { $0.canApprove })
        }
    }

    func loadOlder() async {
        guard let history, let before = history.next_before else { return }
        await run {
            let older: MessengerHistory = try await self.fetch("/api/chats/" + Self.encode(history.chat.id) + "?before=" + Self.encode(before))
            let currentIDs = Set(self.messages.map(\.id))
            self.messages = older.messages.filter { !currentIDs.contains($0.id) } + self.messages
            self.history = older
        }
    }

    func generate(instruction: String) async {
        guard let chat = history?.chat else { return }
        await run {
            let envelope: DraftEnvelope = try await self.fetch("/api/drafts", body: ["chat_id": chat.id, "instruction": instruction])
            self.draft = envelope.draft
        }
    }

    func save(text: String, send: Bool = false) async {
        guard let chat = history?.chat else { return }
        await run {
            if send, !chat.isLive { throw MessengerError("Archived conversations are draft-only.") }
            let saved: DraftEnvelope
            if let draft = self.draft {
                guard draft.canApprove else { throw MessengerError("Create a new draft before editing this reply.") }
                saved = try await self.fetch("/api/drafts/" + Self.encode(draft.id), body: ["text": text, "version": draft.version])
            } else {
                saved = try await self.fetch("/api/drafts", body: ["chat_id": chat.id, "text": text])
            }
            self.draft = saved.draft
            if send {
                let sent: DraftEnvelope = try await self.fetch("/api/drafts/" + Self.encode(saved.draft.id) + "/send", body: ["approved": true, "version": saved.draft.version])
                self.draft = sent.draft
            }
        }
    }

    func newDraft() { draft = nil }

    func setMode(_ mode: String) async {
        guard let chat = history?.chat else { return }
        await run {
            if mode == "automatic", !chat.isLive { throw MessengerError("Archived conversations are draft-only.") }
            let _: EmptyResponse = try await self.fetch("/api/chats/" + Self.encode(chat.id) + "/mode", body: ["mode": mode])
            let refreshed: MessengerHistory = try await self.fetch("/api/chats/" + Self.encode(chat.id))
            self.history = refreshed
            try await self.loadChats()
        }
    }

    private struct ChatsEnvelope: Decodable { let chats: [MessengerChat] }
    private struct DraftEnvelope: Decodable { let draft: MessengerDraft }
    private struct EmptyResponse: Decodable {}

    private func loadChats() async throws {
        let envelope: ChatsEnvelope = try await fetch("/api/chats")
        chats = envelope.chats
    }

    private func fetch<Response: Decodable>(_ path: String, body: [String: Any]? = nil) async throws -> Response {
        let request = try Self.request(path: path, token: token, body: body)
        let (bytes, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw MessengerError("MessengerDesk returned an invalid response.") }
        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 401 { connected = false }
            let failure = try? JSONDecoder().decode(ErrorResponse.self, from: bytes)
            throw MessengerError(failure?.error ?? "MessengerDesk request failed (\(response.statusCode)).")
        }
        return try JSONDecoder().decode(Response.self, from: bytes)
    }

    private struct ErrorResponse: Decodable { let error: String }

    private func run(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do { try await operation() }
        catch { self.error = error.localizedDescription }
    }
}

private struct MessengerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

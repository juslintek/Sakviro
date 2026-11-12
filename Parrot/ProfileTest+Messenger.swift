import Foundation

extension ProfileTest {
    @MainActor
    static func testMessenger() {
        let encoded = MessengerService.encode("chat/with?query&fragment#")
        check("messenger: conversation IDs cannot change request path", encoded == "chat%2Fwith%3Fquery%26fragment%23")
        do {
            let request = try MessengerService.request(path: "/api/chats/" + encoded, token: "test-token")
            check("messenger: only fixed loopback endpoint", request.url?.host == "127.0.0.1" && request.url?.port == 8766)
            check("messenger: bearer stays in headers", request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" && request.url?.query == nil)
            let send = try MessengerService.request(path: "/api/drafts/reply/send", token: "test-token", body: ["approved": true, "version": 2])
            let approval = try JSONSerialization.jsonObject(with: send.httpBody!) as? [String: Any]
            check("messenger: approval carries reviewed version", send.httpMethod == "POST" && approval?["approved"] as? Bool == true && approval?["version"] as? Int == 2)
        } catch { check("messenger: valid local requests build", false) }
        for path in ["https://example.com/api/status", "//example.com/api/status", "/api/status#fragment"] {
            do {
                _ = try MessengerService.request(path: path, token: "test-token")
                check("messenger: rejects unsafe path", false)
            } catch { check("messenger: rejects unsafe path", true) }
        }
        do {
            _ = try MessengerService.request(path: "/api/status", token: "invalid\nheader")
            check("messenger: rejects multiline credential", false)
        } catch { check("messenger: rejects multiline credential", true) }
        let accepted = MessengerDraft(id: "draft", chat_id: "chat", text: "Example", state: "accepted", version: 1)
        let uncertain = MessengerDraft(id: "draft", chat_id: "chat", text: "Example", state: "uncertain", version: 1)
        check("messenger: accepted is not shown as delivered", !accepted.canApprove && accepted.statusText.contains("unconfirmed"))
        check("messenger: uncertain reply requires checking Messenger", !uncertain.canApprove && uncertain.statusText.contains("Check Messenger"))
        let statusJSON = Data(#"{"meta":{"connected":true,"error":""}}"#.utf8)
        do {
            let status = try JSONDecoder().decode(MessengerStatus.self, from: statusJSON)
            check("messenger: native Meta connection decodes", status.meta.connected)
        } catch { check("messenger: native Meta connection decodes", false) }
        for source in ["archive", "beeper", "unknown"] {
            let chat = MessengerChat(id: "synthetic", title: "Synthetic", source: source, mode: "review", is_group: false)
            check("messenger: archived and legacy sources are draft-only", !chat.isLive)
        }
        let liveChat = MessengerChat(id: "synthetic", title: "Synthetic", source: "meta", mode: "review", is_group: false)
        check("messenger: only native Meta source allows sending", liveChat.isLive)
        let stale = MessengerDraft(id: "draft", chat_id: "chat", text: "Example", state: "stale", version: 1)
        check("messenger: stale replies cannot reuse approval", !stale.canApprove)
        let archive = """
        {"chat":{"id":"lt/1","title":"Žinutės","source":"archive","mode":"review"},"messages":[{"id":"m1","sender":"Linas","text":"ąčęėįšųūž","timestamp":"2026-11-09T12:00:00.000+00:00","outgoing":true}],"drafts":[],"style":{"profile":{"sample_count":1,"median_characters":9},"examples":[{"text":"ąčęėįšųūž"}]}}
        """
        do {
            let history = try JSONDecoder().decode(MessengerHistory.self, from: Data(archive.utf8))
            check("messenger: Unicode names and source text survive decoding", history.chat.title == "Žinutės" && history.messages.first?.text == "ąčęėįšųūž")
            check("messenger: style evidence stays attached to its source", history.style?.profile?.sample_count == 1 && history.style?.examples?.first?.text == history.messages.first?.text)
        } catch { check("messenger: history and style decode", false) }
    }
}

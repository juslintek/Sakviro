import SwiftUI

struct MessengerView: View {
    let service: MessengerService
    @State private var connectionToken = ""
    @State private var search = ""
    @State private var reply = ""
    @State private var instruction = ""
    @State private var confirmSend = false
    @State private var confirmAutomatic = false
    @State private var confirmNewDraft = false
    @State private var pendingChat: MessengerChat?

    private var visibleChats: [MessengerChat] {
        service.chats.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.controlGap) {
            HStack {
                Text("Messenger").font(Theme.Typography.title())
                Spacer()
                Button("Open MessengerDesk") { service.openMessengerDesk() }
            }
            Text(service.connectionStatus).font(Theme.Typography.secondary).foregroundStyle(Theme.Colors.ink2)
            if !service.connected {
                Text("Open the native MessengerDesk app. Parrot connects with its local token and stores it in macOS Keychain. You can also paste the token here.")
                    .font(Theme.Typography.body)
                HStack {
                    SecureField("MessengerDesk connection token", text: $connectionToken)
                    Button("Connect") {
                        Task {
                            if connectionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                await service.restore()
                            } else {
                                await service.connect(connectionToken)
                            }
                            if service.connected { connectionToken = "" }
                        }
                    }.disabled(service.isBusy)
                }
            }
            if let error = service.error {
                Text(error).foregroundStyle(Theme.Colors.stop).textSelection(.enabled)
            }
            if service.isBusy { ProgressView().controlSize(.small) }
            HSplitView {
                VStack(alignment: .leading, spacing: Theme.Metrics.controlGap) {
                    TextField("Search conversations", text: $search)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Theme.Metrics.chipInsetV) {
                            ForEach(visibleChats) { chat in
                                Button {
                                    if reply != (service.draft?.text ?? "") {
                                        pendingChat = chat
                                    } else {
                                        instruction = ""
                                        Task { await service.select(chat) }
                                    }
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(chat.title).lineLimit(2)
                                        Text(chat.mode == "automatic" ? "Automatic" : "Review before sending")
                                            .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.ink2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(Theme.Metrics.popoverPad)
                                    .background(service.history?.chat.id == chat.id ? Theme.Colors.selection : .clear,
                                                in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    Button("Refresh conversations") { Task { await service.refreshChats() } }
                        .disabled(!service.connected)
                }
                .frame(minWidth: Theme.Metrics.chatListWidth, idealWidth: Theme.Metrics.chatListWidth)
                .padding(.trailing, Theme.Metrics.controlGap)
                if let history = service.history {
                    conversation(history)
                } else {
                    ContentUnavailableView("Choose a conversation", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Sign in to Meta and sync in the native MessengerDesk app, or import your Meta export there."))
                }
            }
        }
        .font(Theme.Typography.body)
        .padding(Theme.Metrics.pad)
        .background(Theme.Colors.canvas)
        .disabled(service.isBusy)
        .task { await service.restore() }
        .onChange(of: service.draft?.id) { _, _ in reply = service.draft?.text ?? "" }
        .onChange(of: service.draft?.version) { _, _ in reply = service.draft?.text ?? "" }
        .confirmationDialog("Send this reply to \(service.history?.chat.title ?? "this conversation")?", isPresented: $confirmSend) {
            Button("Approve and send") { Task { await service.save(text: reply, send: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(reply)
        }
        .confirmationDialog("Enable automatic replies for \(service.history?.chat.title ?? "this conversation")?", isPresented: $confirmAutomatic) {
            Button("Enable automatic replies") { Task { await service.setMode("automatic") } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MessengerDesk will generate and send replies in this conversation while its automatic worker is running. You can switch back to review at any time.")
        }
        .confirmationDialog("Discard unsaved reply changes?", isPresented: Binding(get: { pendingChat != nil }, set: { if !$0 { pendingChat = nil } })) {
            Button("Discard and open conversation", role: .destructive) {
                guard let chat = pendingChat else { return }
                pendingChat = nil
                instruction = ""
                Task { await service.select(chat) }
            }
            Button("Cancel", role: .cancel) { pendingChat = nil }
        }
        .confirmationDialog("Create another reply after an uncertain send?", isPresented: $confirmNewDraft) {
            Button("Create new draft") { service.newDraft(); reply = "" }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Check Messenger for the previous reply first. Its send outcome is uncertain.")
        }
    }

    private func conversation(_ history: MessengerHistory) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.controlGap) {
            HStack {
                VStack(alignment: .leading) {
                    Text(history.chat.title).font(Theme.Typography.heroTitle)
                    Text(history.chat.mode == "automatic" ? "Automatic replies enabled" : "Review before sending")
                        .font(Theme.Typography.secondary).foregroundStyle(Theme.Colors.ink2)
                }
                Spacer()
                if history.chat.mode == "automatic" {
                    Button("Switch to review") { Task { await service.setMode("review") } }
                } else if history.chat.isLive, history.chat.is_group != true {
                    Button("Enable automatic…") { confirmAutomatic = true }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Metrics.controlGap) {
                    if history.next_before != nil {
                        Button("Load older messages") { Task { await service.loadOlder() } }
                    }
                    ForEach(service.messages) { message in
                        VStack(alignment: .leading, spacing: Theme.Metrics.chipInsetV) {
                            HStack {
                                Text(message.sender).font(Theme.Typography.cardTitle)
                                Text(message.timestamp ?? "").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.ink2)
                            }
                            Text(message.text).textSelection(.enabled)
                        }
                        .padding(Theme.Metrics.popoverPad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(message.outgoing == true ? Theme.Colors.selection : Theme.Colors.panel,
                                    in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                    }
                }
            }
            Divider()
            if let style = history.style {
                DisclosureGroup("Writing style · \(style.profile?.sample_count ?? 0) outgoing samples") {
                    VStack(alignment: .leading, spacing: Theme.Metrics.controlGap) {
                        if let characters = style.profile?.median_characters {
                            Text("Typical reply length: \(Int(characters)) characters")
                        }
                        ForEach(Array((style.examples ?? []).enumerated()), id: \.offset) { _, example in
                            Text(example.text).textSelection(.enabled)
                        }
                    }
                    .font(Theme.Typography.secondary)
                    .padding(Theme.Metrics.popoverPad)
                }
            }
            TextField("Optional reply instruction", text: $instruction)
            TextEditor(text: $reply)
                .font(Theme.Typography.body)
                .frame(minHeight: Theme.Metrics.floatingClearance, maxHeight: Theme.Metrics.chatListWidth)
                .accessibilityLabel("Reply draft")
                .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).stroke(Theme.Colors.line))
                .disabled(service.draft.map { !$0.canApprove } == true)
            if let draft = service.draft {
                Text(draft.statusText).font(Theme.Typography.secondary).foregroundStyle(Theme.Colors.ink2)
            }
            HStack {
                Button("Generate locally") { Task { await service.generate(instruction: instruction) } }
                Button("Save draft") { Task { await service.save(text: reply) } }
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.draft.map { !$0.canApprove } == true)
                if service.draft.map({ !$0.canApprove }) == true {
                    Button("New draft") {
                        if service.draft?.state == "uncertain" { confirmNewDraft = true }
                        else { service.newDraft(); reply = "" }
                    }
                }
                Spacer()
                Button("Approve and send…") { confirmSend = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !history.chat.isLive || service.draft.map { !$0.canApprove } == true)
            }
            Text("Generation and archived conversations stay on this Mac. Open the native MessengerDesk app for style evidence, archive search and imports.")
                .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.ink2)
        }
        .padding(.leading, Theme.Metrics.controlGap)
    }
}

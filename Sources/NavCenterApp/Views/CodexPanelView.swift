import AppKit
import SwiftUI

struct CodexChatLauncher: View {
    @EnvironmentObject private var store: DashboardStore
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if isPresented {
                CodexPanelView(isPresented: $isPresented)
                    .environmentObject(store)
                    .transition(.scale(scale: 0.96, anchor: .bottomTrailing).combined(with: .opacity))
            }

            Button {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                    isPresented.toggle()
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 58, height: 58)
                        .shadow(color: .black.opacity(0.24), radius: 14, y: 6)

                    Image(systemName: isPresented ? "xmark" : "message.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)

                    if !store.codexMessages.isEmpty && !isPresented {
                        Text("\(min(store.codexMessages.count, 9))")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Color.red, in: Circle())
                            .offset(x: 2, y: -2)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(isPresented ? "Close Codex chat" : "Open Codex chat")
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: isPresented)
    }
}

struct CodexPanelView: View {
    @EnvironmentObject private var store: DashboardStore
    @Binding var isPresented: Bool
    @State private var prompt = ""
    @State private var allowEdits = false
    @State private var confirmedEdits = false

    private var accountLabel: String {
        if let account = store.codexStatus?.account {
            if let email = account.email {
                return "\(email) (\(account.planType ?? account.type))"
            }
            return account.type
        }
        return "Not signed in"
    }

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.selectedPackage != nil
            && store.codexStatus?.account != nil
            && !store.isCodexLoading
            && (!allowEdits || confirmedEdits)
    }

    private var selectedPackageLabel: String {
        guard let selectedPackage = store.selectedPackage else {
            return "No package open"
        }
        return (selectedPackage.application?.role ?? "")
            .nonEmptyFallback(selectedPackage.package.role)
            .nonEmptyFallback(selectedPackage.package.name)
    }

    private var packageContextLabel: String {
        guard let selectedPackage = store.selectedPackage else {
            return "Choose a package before sending"
        }
        let applicationCompany = selectedPackage.application?.company ?? ""
        return applicationCompany
            .nonEmptyFallback(selectedPackage.package.company)
            .nonEmptyFallback(selectedPackage.package.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            accountStrip

            if let message = store.codexErrorMessage {
                errorBanner(message)
            }

            Divider()
            chatHistory
            Divider()
            composer
        }
        .frame(width: 420, height: 560)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 26, y: 12)
        .task {
            await store.refreshCodexStatus()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.16))
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex")
                    .font(.headline)
                Text("Package chat history")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await store.refreshCodexStatus() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .disabled(store.isCodexLoading)
            .help("Refresh Codex account")

            Button {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                    isPresented = false
                }
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close Codex chat")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var accountStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(accountLabel, systemImage: store.codexStatus?.account == nil ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle.badge.checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(store.codexStatus?.account == nil ? .orange : .green)
                    .lineLimit(1)

                Spacer()

                if store.codexLogin == nil && store.codexStatus?.account == nil {
                    Button("Sign In") {
                        Task { await store.startCodexLogin(type: "chatgpt") }
                    }
                    .disabled(store.isCodexLoading)

                    Button("Code") {
                        Task { await store.startCodexLogin(type: "chatgptDeviceCode") }
                    }
                    .disabled(store.isCodexLoading)
                }
            }

            if let login = store.codexLogin {
                CodexLoginInstructions(login: login)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var chatHistory: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.codexMessages.isEmpty {
                        emptyHistory
                    } else {
                        ForEach(store.codexMessages) { message in
                            CodexMessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.52))
            .onAppear {
                scrollToLatest(proxy)
            }
            .onChange(of: store.codexMessages.count) { _ in
                scrollToLatest(proxy)
            }
        }
    }

    private var emptyHistory: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("No chat history yet")
                .font(.headline)
            Text(emptyChatMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, minHeight: 230)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(selectedPackageLabel, systemImage: store.selectedPackage == nil ? "folder.badge.questionmark" : "folder.badge.person.crop")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(store.selectedPackage == nil ? .orange : .secondary)
                    .lineLimit(1)
                Spacer()
                Text(packageContextLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            TextEditor(text: $prompt)
                .font(.body)
                .frame(height: 76)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            HStack(spacing: 12) {
                Toggle("Allow edits", isOn: $allowEdits)
                    .toggleStyle(.checkbox)
                    .disabled(store.selectedPackage == nil)
                    .help("Allow Codex to edit package markdown files only")

                if allowEdits {
                    Toggle("Confirm", isOn: $confirmedEdits)
                        .toggleStyle(.checkbox)
                        .foregroundStyle(.orange)
                        .help("Confirm package-local markdown edits for this turn")
                }

                Spacer()

                Button {
                    let message = prompt
                    let editsAllowed = allowEdits
                    let editsConfirmed = confirmedEdits
                    prompt = ""
                    confirmedEdits = false
                    Task {
                        await store.sendCodexMessage(message, allowEdits: editsAllowed, confirmed: editsConfirmed)
                    }
                } label: {
                    Label(store.isCodexLoading ? "Sending" : "Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
            }

            if store.isCodexLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(14)
    }

    private var emptyChatMessage: String {
        if store.selectedPackage == nil {
            return "Open an application package, then ask Codex to review it or prepare local markdown changes."
        }
        if store.codexStatus?.account == nil {
            return "Sign in through codex app-server before starting a package chat."
        }
        return "Ask Codex to review this package, compare the resume to the posting, or draft local markdown changes."
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.08))
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let id = store.codexMessages.last?.id else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }
}

private struct CodexLoginInstructions: View {
    var login: CodexLoginStartResponse

    private var loginURL: URL? {
        if let verificationUrl = login.verificationUrl, let url = URL(string: verificationUrl) {
            return url
        }
        if let authUrl = login.authUrl, let url = URL(string: authUrl) {
            return url
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let userCode = login.userCode {
                HStack {
                    Text("Device code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(userCode)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                }
            }

            if let url = loginURL {
                HStack {
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Open") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Text("Refresh after sign-in completes.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CodexMessageBubble: View {
    var message: CodexChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 42)
            }

            VStack(alignment: textAlignment, spacing: 5) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(labelColor)
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(textColor)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: 320, alignment: bubbleTextAlignment)
            .background(background, in: RoundedRectangle(cornerRadius: 16))

            if message.role != .user {
                Spacer(minLength: 42)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var label: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "Codex"
        case .system: return "System"
        }
    }

    private var textAlignment: HorizontalAlignment {
        message.role == .user ? .trailing : .leading
    }

    private var bubbleTextAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var background: Color {
        switch message.role {
        case .user: return Color.accentColor
        case .assistant: return Color(nsColor: .controlBackgroundColor)
        case .system: return Color.orange.opacity(0.12)
        }
    }

    private var textColor: Color {
        message.role == .user ? .white : Color(nsColor: .labelColor)
    }

    private var labelColor: Color {
        message.role == .user ? .white.opacity(0.82) : .secondary
    }
}

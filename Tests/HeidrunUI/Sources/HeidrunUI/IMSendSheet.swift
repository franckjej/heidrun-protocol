import SwiftUI
import HeidrunCore

/// Modal composer for sending a Hotline instant message. ⌘⏎ sends, Esc cancels.
/// On error, the sheet stays open with an inline banner and the text preserved.
public struct IMSendSheet: View {
    public let recipient: User
    public let onSend: (String) async throws -> Void
    public let onDismiss: () -> Void

    @State private var messageBody: String = ""
    @State private var sending: Bool = false
    @State private var error: String?

    public init(
        recipient: User,
        onSend: @escaping (String) async throws -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.recipient = recipient
        self.onSend = onSend
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send message to \(recipient.nickname)")
                .font(.headline)

            TextEditor(text: $messageBody)
                .font(.body.monospaced())
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.separator)
                )

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Send") { Task { await send() } }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(canSubmit == false || sending)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var canSubmit: Bool {
        !messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            try await onSend(messageBody)
            onDismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}

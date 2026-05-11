import SwiftUI
import HeidrunCore

/// Read-only modal showing extended profile info for a single user. The
/// caller provides the fetch closure; the sheet handles loading / error /
/// retry / display states internally.
public struct UserInfoSheet: View {
    public let nickname: String
    /// Numeric icon ID used to look up the header thumbnail in the
    /// bundled icon catalog. Pass `nil` when the caller has no iconID
    /// yet (e.g. opening this from a Tracker row); the header falls
    /// back to a generic SF Symbol.
    public let iconID: Int?
    public let fetch: () async throws -> UserInfo
    public let onDismiss: () -> Void

    @State private var info: UserInfo?
    @State private var error: String?
    @State private var loading: Bool = true

    public init(
        nickname: String,
        iconID: Int? = nil,
        fetch: @escaping () async throws -> UserInfo,
        onDismiss: @escaping () -> Void
    ) {
        self.nickname = nickname
        self.iconID = iconID
        self.fetch = fetch
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                headerIcon
                Text("Info for \(nickname)")
                    .font(.headline)
            }

            content

            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460, height: 360)
        .task { await load() }
    }

    @ViewBuilder
    private var headerIcon: some View {
        if let iconID, let cg = IconCatalog.shared.cgImage(forID: iconID) {
            Image(decorative: cg, scale: 1, orientation: .up)
                .interpolation(.none)
                .resizable()
                .frame(width: 32, height: 32)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .frame(width: 32, height: 32)
                .symbolRenderingMode(.hierarchical)
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack { Spacer(); ProgressView(); Spacer() }
                .frame(maxWidth: .infinity)
        } else if let error {
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn't load info: \(error)")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Button("Retry") { Task { await load() } }
            }
        } else if let info {
            VStack(alignment: .leading, spacing: 6) {
                row("Nickname", info.user.nickname)
                row("Socket", "\(info.user.socket)")
                row("Status", "0x\(String(info.user.status.rawValue, radix: 16, uppercase: false))")
                row("Privileges", "0x\(String(info.user.privileges.rawValue, radix: 16, uppercase: false))")
                Divider()
                Text("Profile")
                    .font(.subheadline.bold())
                TextEditor(text: .constant(info.infoText))
                    .font(.body.monospaced())
                    .disabled(true)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.separator)
                    )
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(label):")
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            info = try await fetch()
            loading = false
        } catch {
            self.error = String(describing: error)
            loading = false
        }
    }
}

import SwiftUI
import AppKit
import HeidrunCore

/// Trailing-column inspector showing the current server's user roster.
/// Selection drives the toolbar/context-menu actions; double-click is a
/// shortcut for "Send Message".
public struct UserListInspector: View {
    @Bindable public var viewModel: UserListViewModel
    public var onSendMessage: (User) -> Void
    public var onGetInfo: (User) -> Void

    @State private var selection: UInt16?

    public init(
        viewModel: UserListViewModel,
        onSendMessage: @escaping (User) -> Void,
        onGetInfo: @escaping (User) -> Void
    ) {
        self.viewModel = viewModel
        self.onSendMessage = onSendMessage
        self.onGetInfo = onGetInfo
    }

    public var body: some View {
        List(selection: $selection) {
            if let loadError = viewModel.loadError {
                Section {
                    Text("Couldn't fetch user list: \(loadError)")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Section {
                ForEach(viewModel.users) { user in
                    row(for: user)
                        .tag(user.socket)
                        .contextMenu { contextMenu(for: user) }
                }
            }
        }
        .navigationTitle("Users")
        .onChange(of: viewModel.users) { _, _ in
            if let s = selection, !viewModel.users.contains(where: { $0.socket == s }) {
                selection = nil
            }
        }
    }

    @ViewBuilder
    private func row(for user: User) -> some View {
        HStack(spacing: 8) {
            iconView(for: user)
            VStack(alignment: .leading, spacing: 1) {
                Text(user.nickname.isEmpty ? "(no name)" : user.nickname)
                    .foregroundStyle(nameTint(for: user))
                if let suffix = statusSuffix(for: user) {
                    Text(suffix)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .gesture(
            TapGesture(count: 2).onEnded { onSendMessage(user) }
        )
    }

    private func nameTint(for user: User) -> Color {
        if user.status.flags.contains(.admin) || user.status.flags.contains(.sysOp) {
            return .red
        }
        if user.status.flags.contains(.away) {
            return .secondary
        }
        return .primary
    }

    @ViewBuilder
    private func iconView(for user: User) -> some View {
        if let cg = IconCatalog.shared.cgImage(forID: Int(user.icon)) {
            Image(decorative: cg, scale: 1, orientation: .up)
                .interpolation(.none)            // crisp pixels at the icon's native 16x16
                .resizable()
                .frame(width: 16, height: 16)
                .opacity(user.status.flags.contains(.away) ? 0.5 : 1.0)
        } else {
            // Fallback when the iconID isn't in the bundled catalog
            // (e.g. a server using a custom icon set we don't ship).
            Image(systemName: "person.crop.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(rowTint(for: user))
        }
    }

    @ViewBuilder
    private func contextMenu(for user: User) -> some View {
        Button("Send Message…") { onSendMessage(user) }
        Button("Get Info…") { onGetInfo(user) }
        Divider()
        Button("Copy Nickname") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(user.nickname, forType: .string)
        }
    }

    private func rowTint(for user: User) -> Color {
        // Admin/sysOp gets red. Away dims to secondary. Else accent.
        if user.status.flags.contains(.admin) || user.status.flags.contains(.sysOp) {
            return .red
        }
        if user.status.flags.contains(.away) {
            return .secondary
        }
        return .accentColor
    }

    private func statusSuffix(for user: User) -> String? {
        var bits: [String] = []
        if user.status.flags.contains(.away) { bits.append("Away") }
        if user.status.flags.contains(.inPrivateChat) { bits.append("In Chat") }
        return bits.isEmpty ? nil : "(\(bits.joined(separator: " · ")))"
    }
}

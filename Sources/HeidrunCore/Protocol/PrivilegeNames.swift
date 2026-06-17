/// Stable string names for every `UserPrivileges` bit, so CLIs and admin tools
/// can grant/revoke/list privileges by name. Order matches the bit order in
/// `UserPrivileges`. (40 named bits; bit 19 is unused.)
public enum PrivilegeNames {
    public static let table: [(name: String, value: UserPrivileges)] = [
        ("deleteFiles", .deleteFiles), ("uploadFiles", .uploadFiles),
        ("downloadFiles", .downloadFiles), ("renameFiles", .renameFiles),
        ("moveFiles", .moveFiles), ("createFolders", .createFolders),
        ("deleteFolders", .deleteFolders), ("renameFolders", .renameFolders),
        ("moveFolders", .moveFolders), ("readChat", .readChat),
        ("sendChat", .sendChat), ("initiatePrivateChat", .initiatePrivateChat),
        ("closePrivateChat", .closePrivateChat), ("showInList", .showInList),
        ("createUser", .createUser), ("deleteUser", .deleteUser),
        ("readUser", .readUser), ("modifyUser", .modifyUser),
        ("changeOwnPassword", .changeOwnPassword), ("readNews", .readNews),
        ("postNews", .postNews), ("disconnectUsers", .disconnectUsers),
        ("cannotBeDisconnected", .cannotBeDisconnected), ("getUserInfo", .getUserInfo),
        ("uploadAnywhere", .uploadAnywhere), ("useAnyName", .useAnyName),
        ("dontShowAgreement", .dontShowAgreement), ("commentFiles", .commentFiles),
        ("commentFolders", .commentFolders), ("viewDropBoxes", .viewDropBoxes),
        ("makeAliases", .makeAliases), ("canBroadcast", .canBroadcast),
        ("deleteArticles", .deleteArticles), ("createCategories", .createCategories),
        ("deleteCategories", .deleteCategories), ("createNewsBundles", .createNewsBundles),
        ("deleteNewsBundles", .deleteNewsBundles), ("uploadFolders", .uploadFolders),
        ("downloadFolders", .downloadFolders), ("sendMessages", .sendMessages)
    ]

    public static var allNames: [String] { table.map(\.name) }

    public static func value(for name: String) -> UserPrivileges? {
        let needle = name.lowercased()
        return table.first { $0.name.lowercased() == needle }?.value
    }

    public static func names(in privileges: UserPrivileges) -> [String] {
        table.filter { privileges.contains($0.value) }.map(\.name)
    }

    public static func parse(_ csv: String) -> (matched: UserPrivileges, unknown: [String]) {
        var matched = UserPrivileges()
        var unknown: [String] = []
        for raw in csv.split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            if let value = value(for: name) { matched.formUnion(value) } else { unknown.append(name) }
        }
        return (matched, unknown)
    }
}

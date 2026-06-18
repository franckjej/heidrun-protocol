/// Version of the heidrun-protocol package — the value layer (`HeidrunCore`),
/// both transports (`HotlineNetworkClient`, `HeidrunNIOClient`), and the
/// `heidrun` CLI all share it.
///
/// The semver string is hand-maintained: bump it alongside the release tag
/// (e.g. when cutting `1.0.0-rc24`). Surfaced by the CLI's `/version` command
/// and `heidrun --version`.
public enum HeidrunProtocolInfo {
    /// Semantic version of the package. Bumped manually each release.
    public static let version: String = "1.0.0-rc23"
}

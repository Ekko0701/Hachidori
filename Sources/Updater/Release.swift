import Foundation

/// The parts of a GitHub release (`GET /repos/{owner}/{repo}/releases/latest`) the updater uses.
public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let size: Int
        public let browserDownloadURL: URL
        /// `sha256:<hex>`; GitHub fills it in for assets uploaded since mid-2025.
        public let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    public let tagName: String
    public let htmlURL: URL
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    /// The update this release offers to an app at `current`, or nil when it is not
    /// newer, is a draft or pre-release, or has no `<appName>-<version>.dmg` asset.
    public func update(newerThan current: AppVersion, appName: String) -> AvailableUpdate? {
        guard !draft, !prerelease, let version = AppVersion(tagName), version > current else { return nil }
        let dmgName = "\(appName)-\(version).dmg"
        guard let dmg = assets.first(where: { $0.name == dmgName }) else { return nil }
        var sha256: String?
        if let digest = dmg.digest?.lowercased(), digest.hasPrefix("sha256:") {
            sha256 = String(digest.dropFirst("sha256:".count))
        }
        return AvailableUpdate(version: version, releaseURL: htmlURL,
                               notes: body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                               dmgURL: dmg.browserDownloadURL, dmgSize: dmg.size, sha256: sha256)
    }
}

/// A newer release the user can install.
public struct AvailableUpdate: Equatable, Sendable {
    public let version: AppVersion
    public let releaseURL: URL
    public let notes: String
    public let dmgURL: URL
    public let dmgSize: Int
    /// Lowercase hex SHA-256 of the DMG, when GitHub reports one.
    public let sha256: String?

    public init(version: AppVersion, releaseURL: URL, notes: String, dmgURL: URL, dmgSize: Int, sha256: String?) {
        self.version = version
        self.releaseURL = releaseURL
        self.notes = notes
        self.dmgURL = dmgURL
        self.dmgSize = dmgSize
        self.sha256 = sha256
    }
}

/// Asks GitHub for the latest published release. The repository is public, so no token is needed.
public struct UpdateChecker: Sendable {
    public let owner: String
    public let repo: String
    public let appName: String

    public init(owner: String, repo: String, appName: String) {
        self.owner = owner
        self.repo = repo
        self.appName = appName
    }

    /// The newer release, or nil when `current` is already the latest.
    public func check(current: AppVersion, session: URLSession = .shared) async throws -> AvailableUpdate? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(appName, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 404: the repository has no published release yet.
        if status == 404 { return nil }
        guard status == 200 else { throw UpdateError.server(status) }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        return release.update(newerThan: current, appName: appName)
    }
}

public enum UpdateError: LocalizedError, Equatable {
    case server(Int)
    case download(Int)
    case checksumMismatch
    case mountFailed(String)
    case appMissing(String)
    case untrusted(String)
    case wrongVersion(expected: String, found: String)
    case cannotInstall(String)

    public var errorDescription: String? {
        switch self {
        case .server(let status): "GitHub answered with HTTP \(status)."
        case .download(let status): "The download failed with HTTP \(status)."
        case .checksumMismatch: "The downloaded file doesn't match the release's checksum."
        case .mountFailed(let detail): "Couldn't open the downloaded disk image. \(detail)"
        case .appMissing(let name): "The disk image doesn't contain \(name)."
        case .untrusted(let detail): "The new version isn't signed by the Hachidori developer. \(detail)"
        case .wrongVersion(let expected, let found): "Expected version \(expected) but the download is \(found)."
        case .cannotInstall(let detail): detail
        }
    }
}

import Foundation

/// 检查更新：读 GitHub Releases 的最新 tag，和当前 `CFBundleShortVersionString` 比大小。
///
/// 安装包只发在 GitHub Release 里（`dist/` 的 dmg / zip，由 `scripts/release.sh` 上传），
/// 所以这里不引 Sparkle（要额外依赖、自建 appcast，还得托管签名），只做三件事：
///   1. `GET /repos/{owner}/{repo}/releases/latest` —— 这个端点本身就不含 draft 与 prerelease；
///   2. 比版本号（按 `.` 分段比数字，见 `isNewer`）；
///   3. 有新版就把 `.dmg`（没有就 `.zip`）下到 `~/Downloads`，在 Finder 里选中。
///
/// 没有缓存、没有轮询、没有自动下载：只在用户点菜单时发一次请求。
/// 未认证的 GitHub API 是 60 次/小时/IP，一次点击一次请求，够用。
enum UpdateChecker {
    static let owner = "robbietree8"
    static let repo = "MacBleUnlock"

    struct Release: Equatable, Sendable {
        /// 去掉 `v` 前缀的 tag，例如 `1.0.3`。
        var version: String
        /// release 页面（浏览器打开）。
        var pageURL: URL
        /// 优先 `.dmg`，其次 `.zip`；两个都没有就是 nil，菜单只提供「打开发布页」。
        var downloadURL: URL?
        /// 落地文件名，取自 asset 自己的名字。
        var downloadName: String?
    }

    enum CheckResult: Equatable, Sendable {
        case upToDate(current: String)
        case available(current: String, release: Release)
        /// 网络 / HTTP / 解析失败。这句话会原样进菜单，所以只放一句话，细节留给日志。
        case failed(String)
    }

    enum DownloadError: LocalizedError, Equatable {
        case noAsset
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .noAsset: "该 release 没有 dmg / zip 安装包"
            case .http(let code): "HTTP \(code)"
            }
        }
    }

    /// 当前运行的 `.app` 的版本号。和菜单里显示的版本号同源。
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func check(current: String = currentVersion) async -> CheckResult {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacBleUnlock/\(current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let data: Data
        let http: HTTPURLResponse
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            guard let status = response as? HTTPURLResponse else { return .failed("响应异常") }
            data = body
            http = status
        } catch {
            return .failed("网络不可用")
        }
        // 403 = 触发限额，404 = 还没有 release，其它非 200 也在这里。
        guard http.statusCode == 200 else { return .failed("HTTP \(http.statusCode)") }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            return .failed("响应解析失败")
        }

        let version = payload.tagName.hasPrefix("v") ? String(payload.tagName.dropFirst()) : payload.tagName
        guard isNewer(version, than: current) else { return .upToDate(current: current) }

        // 安装包选 dmg：`release.sh` 两个都传，dmg 是给用户双击挂载的那份。
        let preferred = ["dmg", "zip"].lazy.compactMap { ext in
            payload.assets.first { $0.name.lowercased().hasSuffix(".\(ext)") }
        }.first

        return .available(current: current, release: Release(
            version: version,
            pageURL: payload.htmlURL,
            downloadURL: preferred?.browserDownloadURL,
            downloadName: preferred?.name
        ))
    }

    /// 下载安装包到 `directory`（默认 `~/Downloads`），返回落地路径。
    ///
    /// 同名文件已存在时**不覆盖**，改成 `名字 2.dmg`——不删用户已有的文件。
    static func download(_ release: Release, into directory: URL? = nil) async throws -> URL {
        guard let remote = release.downloadURL else { throw DownloadError.noAsset }

        var request = URLRequest(url: remote)
        request.setValue("MacBleUnlock/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 300  // 安装包 ~1.7MB，但慢网也别中途放弃
        let (temp, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.http(0) }
        guard http.statusCode == 200 else { throw DownloadError.http(http.statusCode) }

        let folder = directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = release.downloadName ?? remote.lastPathComponent
        let target = unusedURL(named: name, in: folder)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    /// `1.0.3` > `1.0.2`、`1.0.10` > `1.0.9`（逐段比数字，不是比字符串）、`v1.0.3` == `1.0.3`。
    /// 段数不一致时短的一侧补 0（`1.1` > `1.0.9`）。`v` 前缀与预发布 / build 后缀整个丢掉：
    /// `1.0.3-beta.1` 按 `1.0.3` 算（只取开头连续的 `数字.数字`，否则 `beta.1` 会多出两个段）。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = numericSegments(candidate)
        let rhs = numericSegments(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func numericSegments(_ version: String) -> [Int] {
        let trimmed = version.hasPrefix("v") ? version.dropFirst() : Substring(version)
        // 只取开头连续的 `数字.数字` 部分：`1.0.3-beta.1` → `1.0.3`。
        // 先截断再分段，不能只对每段取前导数字 —— `2-beta` 那种段后面还跟着 `.1`，会多出段来。
        let core = trimmed.prefix { $0.isNumber || $0 == "." }
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    private static func unusedURL(named name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path), index < 100 {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    private struct Payload: Decodable {
        var tagName: String
        var htmlURL: URL
        var assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }

        struct Asset: Decodable {
            var name: String
            var browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
    }
}

import Foundation
import Combine

/// 用户导入的曲谱。原文件复制到 App 的 Documents/Scores 里，下次启动自动加载。
@MainActor
final class ScoreLibrary: ObservableObject {
    @Published private(set) var imported: [Score] = []
    private var files: [UUID: URL] = [:]

    static let extensions: Set<String> = ["musicxml", "xml", "mxl"]

    private let folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scores", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        imported = []
        files = [:]
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where Self.extensions.contains(url.pathExtension.lowercased()) {
            // 已经导入过的文件理论上都能解析；万一不能就跳过
            guard let score = try? load(url) else { continue }
            imported.append(score)
            files[score.id] = url
        }
    }

    /// 从"文件"App 选中的文件导入：先解析成功再复制，失败时抛出原因
    func importFile(at source: URL) throws -> Score {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: source)
        let score = try MusicXMLParser.parse(data: data, fallbackTitle: Self.title(for: source))

        let ext = source.pathExtension.lowercased()
        let base = source.deletingPathExtension().lastPathComponent
        var target = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        try data.write(to: target)

        imported.append(score)
        files[score.id] = target
        return score
    }

    func contains(_ score: Score) -> Bool { files[score.id] != nil }

    func remove(_ score: Score) {
        if let url = files[score.id] { try? FileManager.default.removeItem(at: url) }
        files[score.id] = nil
        imported.removeAll { $0.id == score.id }
    }

    private func load(_ url: URL) throws -> Score {
        try MusicXMLParser.parse(data: Data(contentsOf: url), fallbackTitle: Self.title(for: url))
    }

    private static func title(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

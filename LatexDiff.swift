import Foundation

struct LatexDiffResult: Identifiable {
    let id = UUID()
    let leftTitle: String
    let rightTitle: String
    let summary: String
    let unifiedDiff: String
    let error: String?
}

func safeHistoryFile(root: String, relative: String) -> URL? {
    guard let value = path(in: root, relative: relative) else { return nil }
    let base = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
    let file = URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath()
    guard file.path.hasPrefix(base + "/") else { return nil }
    return file
}

private func latexSections(_ lines: [String]) -> [String] {
    var active = "document"
    return lines.map { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.hasPrefix("%"), let slash = trimmed.range(of: #"\\(chapter|section|subsection|subsubsection)\*?\{"#, options: .regularExpression),
           let close = trimmed[slash.upperBound...].firstIndex(of: "}") {
            active = String(trimmed[slash.upperBound..<close])
        }
        return active
    }
}

func latexDiffSummary(_ unified: String, old: String, new: String, language: String) -> String {
    let oldSections = latexSections(old.components(separatedBy: "\n"))
    let newSections = latexSections(new.components(separatedBy: "\n"))
    var added = 0, removed = 0
    var affected: [String] = []
    for line in unified.components(separatedBy: "\n") {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { added += 1 }
        if line.hasPrefix("-") && !line.hasPrefix("---") { removed += 1 }
        if line.hasPrefix("@@") {
            let fields = line.split(separator: " ")
            for (prefix, sections) in [("-", oldSections), ("+", newSections)] {
                guard let field = fields.first(where: { $0.hasPrefix(prefix) }),
                      let index = Int(field.dropFirst().split(separator: ",")[0]),
                      !sections.isEmpty else { continue }
                let section = sections[max(0, min(index - 1, sections.count - 1))]
                if !affected.contains(section) { affected.append(section) }
            }
        }
    }
    let sectionText = affected.prefix(8).joined(separator: ", ")
    return usesEnglish(language)
        ? "+\(added) / -\(removed) lines · sections: \(sectionText.isEmpty ? "none" : sectionText)"
        : "新增 \(added) 行 · 删除 \(removed) 行 · 涉及章节：\(sectionText.isEmpty ? "未识别" : sectionText)"
}

func makeLatexDiff(left: URL, right: URL, leftTitle: String, rightTitle: String,
                   language: String) -> LatexDiffResult {
    func failure(_ message: String) -> LatexDiffResult {
        LatexDiffResult(leftTitle: leftTitle, rightTitle: rightTitle, summary: "", unifiedDiff: "", error: message)
    }
    do {
        let limit = 1_000_000
        let sizes = try [left, right].map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? limit + 1 }
        guard sizes.allSatisfy({ $0 <= limit }) else {
            return failure(usesEnglish(language) ? "One version exceeds the 1 MB diff limit." : "有版本超过 1 MB 差异查看上限。")
        }
        let oldData = try Data(contentsOf: left)
        let newData = try Data(contentsOf: right)
        guard oldData.count <= limit, newData.count <= limit else {
            return failure(usesEnglish(language) ? "One version exceeds the 1 MB diff limit." : "有版本超过 1 MB 差异查看上限。")
        }
        guard let old = String(data: oldData, encoding: .utf8),
              let new = String(data: newData, encoding: .utf8) else {
            return failure(usesEnglish(language) ? "A version is not UTF-8 text." : "文件不是 UTF-8 文本。")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pathsync-diff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let oldURL = scratch.appendingPathComponent("old.tex")
        let newURL = scratch.appendingPathComponent("new.tex")
        try oldData.write(to: oldURL)
        try newData.write(to: newURL)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        task.arguments = ["-u", "-L", leftTitle, "-L", rightTitle, oldURL.path, newURL.path]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus <= 1 else {
            return failure(String(decoding: data, as: UTF8.self))
        }
        let diff = String(decoding: data, as: UTF8.self)
        return LatexDiffResult(leftTitle: leftTitle, rightTitle: rightTitle,
            summary: latexDiffSummary(diff, old: old, new: new, language: language),
            unifiedDiff: diff.isEmpty ? (usesEnglish(language) ? "Current versions are identical." : "当前两个版本内容相同。") : diff,
            error: nil)
    } catch { return failure(error.localizedDescription) }
}

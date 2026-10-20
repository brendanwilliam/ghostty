import SwiftUI

/// The `.shortcut` files in the local shell's home folder, made by
/// `cherri program.cherri`, with a share sheet for each.
///
/// Files are unsigned unless compiled with `cherri --sign`, which sends the
/// shortcut to a signing service (opt-in, needs a connection).
struct ShortcutFilesView: View {
    @State private var files: [URL] = []

    var body: some View {
        List {
            if files.isEmpty {
                Section {
                    Text("No shortcuts yet.")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Write a program in the terminal (for example with vim) and compile it with `cherri hello.cherri`; add `--sign` while online to sign it. The result appears here.")
                }
            } else {
                Section {
                    ForEach(files, id: \.self) { file in
                        ShareLink(item: file) {
                            Label(file.lastPathComponent, systemImage: "square.and.arrow.up")
                        }
                    }
                } footer: {
                    Text("Signed shortcuts import on any device. Unsigned ones may not.")
                }
            }
        }
        .navigationTitle("Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { files = Self.shortcutFiles(in: LocalEnvironment.home) }
    }

    /// `.shortcut` files under `folder`, newest first, at most a few levels deep.
    static func shortcutFiles(in folder: URL, depth: Int = 3) -> [URL] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [URL] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                if depth > 0 { found += shortcutFiles(in: entry, depth: depth - 1) }
            } else if entry.pathExtension == "shortcut" {
                found.append(entry)
            }
        }
        return found.sorted { modified($0) > modified($1) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

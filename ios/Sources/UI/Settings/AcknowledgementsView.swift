import SwiftUI

/// The open-source software inside the app and the licenses it comes
/// under. The license texts are bundled files (Resources/Licenses).
struct Acknowledgement: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let license: String
    /// Name of the bundled text file, without the extension.
    let file: String

    /// The license text, or nil if the file is missing from the bundle.
    var text: String? {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

enum Acknowledgements {
    struct Group: Identifiable {
        let title: String
        let footer: String?
        let items: [Acknowledgement]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "Python", footer: "python3 in This iPhone. Python's license file also lists the notices for the code it includes.", items: [
            Acknowledgement(id: "python", name: "Python 3.14", detail: "The interpreter and standard library, from BeeWare's Python-Apple-support",
                            license: "Python Software Foundation License", file: "license-python"),
            Acknowledgement(id: "openssl", name: "OpenSSL 3.5", detail: "Used by Python's ssl and hashlib modules",
                            license: "Apache License 2.0", file: "license-openssl"),
            Acknowledgement(id: "libffi", name: "libffi", detail: "Used by Python's ctypes",
                            license: "MIT", file: "license-libffi"),
            Acknowledgement(id: "bzip2", name: "bzip2", detail: "Used by Python's bz2 module",
                            license: "bzip2 license (BSD-style)", file: "license-bzip2"),
            Acknowledgement(id: "xz", name: "XZ Utils", detail: "Used by Python's lzma module",
                            license: "BSD Zero Clause", file: "license-xz"),
            Acknowledgement(id: "zstd", name: "Zstandard", detail: "Used by Python's compression.zstd module",
                            license: "BSD", file: "license-zstd"),
            Acknowledgement(id: "mpdecimal", name: "mpdecimal", detail: "Used by Python's decimal module",
                            license: "BSD 2-Clause", file: "license-mpdecimal"),
        ]),
        Group(title: "Local shell", footer: "The commands in This iPhone. They run inside the app; nothing is downloaded.", items: [
            Acknowledgement(id: "ios-system", name: "ios_system", detail: "Runs commands without processes, and the file, text, shell, awk and tar tools",
                            license: "BSD 3-Clause", file: "license-ios-system"),
            Acknowledgement(id: "dash", name: "dash", detail: "The shell",
                            license: "BSD", file: "license-dash"),
            Acknowledgement(id: "vim", name: "Vim", detail: "The editor",
                            license: "Vim License", file: "license-vim"),
            Acknowledgement(id: "lua", name: "Lua", detail: "Used by Vim",
                            license: "MIT", file: "license-lua"),
            Acknowledgement(id: "libgit2", name: "libgit2", detail: "The lg2 command (git)",
                            license: "GPL 2 with linking exception", file: "license-libgit2"),
            Acknowledgement(id: "libssh2", name: "libssh2", detail: "Used by lg2",
                            license: "BSD 3-Clause", file: "license-libssh2"),
            Acknowledgement(id: "openssl-1", name: "OpenSSL 1.1.1", detail: "Used by lg2",
                            license: "OpenSSL License", file: "license-openssl-1"),
        ]),
        Group(title: "App", footer: nil, items: [
            Acknowledgement(id: "ghostty", name: "Ghostty", detail: "The terminal renderer",
                            license: "MIT", file: "license-ghostty"),
            Acknowledgement(id: "citadel", name: "Citadel", detail: "SSH",
                            license: "MIT", file: "license-citadel"),
            Acknowledgement(id: "swift-nio", name: "SwiftNIO", detail: "Networking, including swift-nio-ssh and swift-nio-transport-services",
                            license: "Apache License 2.0", file: "license-swift-nio"),
        ]),
    ]

    static var all: [Acknowledgement] { groups.flatMap(\.items) }
}

struct AcknowledgementsView: View {
    var body: some View {
        List {
            ForEach(Acknowledgements.groups) { group in
                Section {
                    ForEach(group.items) { item in
                        NavigationLink {
                            LicenseTextView(item: item)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                Text(item.license).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    if let footer = group.footer { Text(footer) }
                }
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LicenseTextView: View {
    let item: Acknowledgement

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                Text(item.text ?? "The license text is missing from this build.")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

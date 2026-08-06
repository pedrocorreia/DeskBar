import SwiftUI
import AppKit

struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)

            Text("DeskBar")
                .font(.title2).bold()

            Text("Version \(shortVersion) (\(buildVersion))")
                .font(.callout).foregroundStyle(.secondary)

            Link("View Releases on GitHub", destination: releasesURL)
                .font(.callout)

            Text("Personal project.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 260)
    }

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var buildVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var releasesURL: URL {
        URL(string: "https://github.com/pedrocorreia/DeskBar/releases")!
    }
}

import AppKit
import SwiftUI

@main
struct VideoCompressorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppViewModel()
    @State private var isAboutPresented = false

    init() {
        AppFont.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup("Media Compressor") {
            ContentView()
                .environmentObject(viewModel)
                .tint(AppColor.accent)
                // Lit Field is a light world; night is a component, not a mode.
                .preferredColorScheme(.light)
                .frame(minWidth: 960, minHeight: 640)
                .sheet(isPresented: $isAboutPresented) {
                    AboutView()
                        .preferredColorScheme(.light)
                }
                .onAppear {
                    let viewModel = viewModel
                    appDelegate.onShouldTerminate = {
                        guard viewModel.hasActiveWork else { return .terminateNow }
                        if viewModel.isRunning {
                            let alert = NSAlert()
                            alert.messageText = "Compression is still running"
                            alert.informativeText = "Quitting stops it and deletes the unfinished output file."
                            alert.addButton(withTitle: "Quit")
                            alert.addButton(withTitle: "Keep Compressing")
                            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
                        }
                        viewModel.stopAllWork {
                            NSApp.reply(toApplicationShouldTerminate: true)
                        }
                        return .terminateLater
                    }
                    appDelegate.onTerminate = {
                        viewModel.removeAllTemporaryFiles()
                    }
                    appDelegate.onOpen = { urls in
                        viewModel.addFiles(urls)
                    }
                    #if DEBUG
                    appDelegate.onDebugAction = { action in
                        switch action {
                        case "review":
                            viewModel.selectedJobID = viewModel.jobs.first?.id
                            viewModel.startCompression()
                            if let id = viewModel.jobs.first?.id { viewModel.renderPreviewSample(for: id) }
                        case "run":
                            viewModel.beginCompression()
                        default:
                            break
                        }
                    }
                    #endif
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Media Compressor") {
                    isAboutPresented = true
                }
            }
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Decides whether the app may quit now. Running ffmpeg processes are
    /// stopped first so no partial output or orphaned process is left behind.
    var onShouldTerminate: (@MainActor () -> NSApplication.TerminateReply)?
    var onTerminate: (@MainActor () -> Void)?
    /// Files dropped on the Dock icon or sent via "Open With". Anything that
    /// arrives before the window wires itself up waits in `pendingURLs`.
    var onOpen: (@MainActor ([URL]) -> Void)? {
        didSet {
            guard let onOpen, !pendingURLs.isEmpty else { return }
            let urls = pendingURLs
            pendingURLs = []
            MainActor.assumeIsolated { onOpen(urls) }
        }
    }
    private var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            if let onOpen {
                onOpen(urls)
            } else {
                pendingURLs += urls
            }
        }
    }

    #if DEBUG
    var onDebugAction: (@MainActor (String) -> Void)?

    /// Visual-check hook for debug builds: `MC_SNAPSHOT=<dir>` writes a PNG of
    /// every window after launch; `MC_SNAPSHOT_FILES` (colon-separated) queues
    /// files first and `MC_SNAPSHOT_ACTION` (`review`/`run`) drives the queue. Renders the app's own views, so it needs no screen-recording
    /// permission. Compiled out of release builds.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["MC_SNAPSHOT"] else { return }
        let files = (environment["MC_SNAPSHOT_FILES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let delay = Double(environment["MC_SNAPSHOT_DELAY"] ?? "") ?? 4

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated { self.onOpen?(files) }
        }
        if let action = environment["MC_SNAPSHOT_ACTION"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                MainActor.assumeIsolated { self.onDebugAction?(action) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                for (index, window) in NSApp.windows.enumerated() {
                    guard let view = window.contentView?.superview ?? window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("window-\(index).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
                if environment["MC_SNAPSHOT_KEEP"] == nil { NSApp.terminate(nil) }
            }
        }
    }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            onShouldTerminate?() ?? .terminateNow
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            onTerminate?()
        }
    }
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetric.l) {
            VStack(alignment: .leading, spacing: 6) {
                Wordmark(size: 26)
                Text("Version \(version)")
                    .uiLabel(12.5, color: AppColor.ink4)
                    .monospacedDigit()
            }

            Hairline()

            VStack(alignment: .leading, spacing: 8) {
                Text("I wanted a quick, reliable media converter, so I made one. It is open source and free. Video and audio are encoded by the bundled FFmpeg.")
                    .font(AppFont.text(14.5))
                    .foregroundStyle(AppColor.ink2)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    Text("Made by Yuri Ihnatov ·")
                        .font(AppFont.text(14.5))
                        .foregroundStyle(AppColor.ink3)
                    Link(destination: URL(string: "https://ihnatov.nl")!) {
                        Text("ihnatov.nl")
                            .font(AppFont.text(14.5, weight: .bold))
                            .foregroundStyle(AppColor.accentOnLight)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.lit(.primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppMetric.xl)
        .frame(width: 440)
        .background(LitField())
    }
}

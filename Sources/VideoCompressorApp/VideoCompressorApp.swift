import SwiftUI

@main
struct VideoCompressorApp: App {
    @StateObject private var viewModel = AppViewModel()
    @State private var isAboutPresented = false

    var body: some Scene {
        WindowGroup("Media Compressor") {
            ContentView()
                .environmentObject(viewModel)
                .tint(.brandOrange)
                .frame(minWidth: 920, minHeight: 620)
                .sheet(isPresented: $isAboutPresented) {
                    AboutView()
                        .tint(.brandOrange)
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Media Compressor") {
                    isAboutPresented = true
                }
            }
            SidebarCommands()
        }
    }
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 42, weight: .regular))
                    .foregroundStyle(Color.brandOrange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Media Compressor")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Version 0.1.0")
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Created by Yuri Ihnatov")
                    .font(.headline)
                Link("ihnatov.nl", destination: URL(string: "https://ihnatov.nl")!)
                Text("I wanted a quick, reliable media converter, so I created this app. It is open source and free.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
    }
}

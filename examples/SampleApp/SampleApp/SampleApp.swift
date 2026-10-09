import SwiftUI

@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("SimPR Sample v2")
                .font(.largeTitle.bold())
            Text("Opened from a pull request with “Run in iOS Simulator”.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Tapped \(taps) times") { taps += 1 }
                .buttonStyle(.borderedProminent)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}

#Preview {
    ContentView()
}

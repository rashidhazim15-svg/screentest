import SwiftUI
import ScreenCaptureKit

final class Probe: NSObject, ObservableObject, SCContentSharingPickerObserver {
    @Published var log: String = "جاهز — اضغط فحص"

    func run() {
        Task {
            do {
                let content = try await SCShareableContent.current
                var text = "شاشات: \(content.displays.count) | تطبيقات: \(content.applications.count)"

                if #available(iOS 27.0, *) {
                    SCContentSharingPicker.shared.add(self)
                    SCContentSharingPicker.shared.present()
                    text += " | تم فتح منتقي آبل"
                } else {
                    text += " | iOS 27 مطلوب"
                }
                publish(text, replace: true)
            } catch {
                publish("خطأ: \(error.localizedDescription)\n\(error)", replace: true)
            }
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker,
                              didUpdateWith filter: SCContentFilter,
                              for stream: SCStream?) {
        publish("\nتم استلام إذن المصدر ✓")
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker,
                              didCancelFor stream: SCStream?) {
        publish("\nأُلغي الاختيار")
    }

    private func publish(_ text: String, replace: Bool = false) {
        DispatchQueue.main.async {
            self.log = replace ? text : self.log + text
        }
    }
}

struct ContentView: View {
    @StateObject private var probe = Probe()

    var body: some View {
        VStack(spacing: 18) {
            Text("فحص صلاحية الشاشة — iOS 27")
                .font(.headline)
            Text(probe.log)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            Button("فحص") { probe.run() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }
}

@main
struct ScreenTestApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

import SwiftUI
import ScreenCaptureKit

final class Probe: NSObject, ObservableObject, SCContentSharingPickerObserver {
    @Published var log: String = "جاهز — اضغط فحص"

    func run() {
        let picker = SCContentSharingPicker.shared
        picker.addObserver(self)
        picker.active = true
        picker.present()
        publish("تم فتح منتقي آبل — اختر «الشاشة كاملة»", replace: true)
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

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        publish("\nفشل المنتقي: \(error.localizedDescription)")
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

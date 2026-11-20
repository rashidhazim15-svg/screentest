import SwiftUI
import UIKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage

private let FB_ROOT = "https://chatapp-e436f-default-rtdb.firebaseio.com/%D8%B9%D8%AF%D9%84%D9%88"

struct ChatMessage: Identifiable {
    let id: String
    let user: String
    let text: String
    let ts: Double
}

final class LiveModel: NSObject, ObservableObject {
    @Published var status: String = "جاهز — اضغط «تفعيل الشاشة»"
    @Published var isLive: Bool = false
    @Published var preview: UIImage?
    @Published var messages: [ChatMessage] = []
    @Published var draft: String = ""
    @Published var role: String = UserDefaults.standard.string(forKey: "live_role") ?? "A" {
        didSet { UserDefaults.standard.set(role, forKey: "live_role") }
    }

    private var stream: SCStream?
    private var lastSent: Date = .distantPast
    private var sending: Bool = false
    private var chatTimer: Timer?
    private let ciContext = CIContext()

    func requestScreen() {
        let picker = SCContentSharingPicker.shared
        picker.add(self)
        picker.isActive = true
        picker.present()
        setStatus("تم فتح منتقي آبل — اختر «الشاشة كاملة»")
    }

    func stopScreen() {
        try? stream?.stopCapture()
        stream = nil
        isLive = false
        setStatus("البث متوقف")
    }

    private func startStream(with filter: SCContentFilter) {
        let cfg = SCStreamConfiguration()
        cfg.width = 360
        cfg.height = 780
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 3)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.capturesAudio = false
        cfg.queueDepth = 3

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue.global(qos: .utility))
            try s.startCapture()
            DispatchQueue.main.async {
                self.stream = s
                self.isLive = true
                self.status = "البث شغال ✓ — افتح صفحة العرض"
            }
        } catch {
            setStatus("فشل بدء البث: \(error.localizedDescription)")
        }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }

    private func put(_ path: String, _ object: [String: Any], done: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: FB_ROOT + "/" + path + ".json") else { done?(false); return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: object, options: [])
        URLSession.shared.dataTask(with: req) { _, _, _ in done?(true) }.resume()
    }

    private func post(_ path: String, _ object: [String: Any]) {
        guard let url = URL(string: FB_ROOT + "/" + path + ".json") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: object, options: [])
        URLSession.shared.dataTask(with: req).resume()
    }

    func startChatPolling() {
        loadChat()
        if chatTimer == nil {
            chatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.loadChat()
            }
        }
    }

    func stopChatPolling() {
        chatTimer?.invalidate()
        chatTimer = nil
    }

    func loadChat() {
        guard let url = URL(string: FB_ROOT + "/chat_messages.json") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            var arr: [ChatMessage] = []
            for (key, value) in obj {
                guard let m = value as? [String: Any] else { continue }
                if m["deleted"] != nil { continue }
                let text = m["text"] as? String ?? ""
                if text.isEmpty { continue }
                let user = m["user"] as? String ?? "?"
                let ts = (m["timestamp"] as? NSNumber)?.doubleValue ?? 0
                arr.append(ChatMessage(id: key, user: user, text: text, ts: ts))
            }
            arr.sort { $0.ts < $1.ts }
            if arr.count > 80 { arr = Array(arr.suffix(80)) }
            DispatchQueue.main.async { self.messages = arr }
        }.resume()
    }

    func sendChat() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let now = Date()
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        post("chat_messages", [
            "user": role,
            "text": text,
            "time": tf.string(from: now),
            "date": df.string(from: now),
            "read": false,
            "timestamp": Int(now.timeIntervalSince1970 * 1000)
        ])
        DispatchQueue.main.async { self.draft = "" }
    }
}

extension LiveModel: SCContentSharingPickerObserver {
    func contentSharingPicker(_ picker: SCContentSharingPicker,
                              didUpdateWith filter: SCContentFilter,
                              for stream: SCStream?) {
        setStatus("✓ تم استلام إذن المصدر — جاري البث")
        startStream(with: filter)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker,
                              didCancelFor stream: SCStream?) {
        setStatus("أُلغي الاختيار — اضغط تفعيل من جديد")
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        setStatus("فشل المنتقي: \(error.localizedDescription)")
    }
}

extension LiveModel: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard !sending else { return }
        guard Date().timeIntervalSince(lastSent) >= 0.45 else { return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let image = CIImage(cvImageBuffer: buffer)
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return }
        let ui = UIImage(cgImage: cg)
        let scaled = ui.preparingThumbnail(of: CGSize(width: 360, height: 780)) ?? ui
        guard let jpeg = scaled.jpegData(compressionQuality: 0.38) else { return }

        sending = true
        lastSent = Date()
        let body: [String: Any] = [
            "b64": jpeg.base64EncodedString(),
            "t": Int(Date().timeIntervalSince1970 * 1000),
            "w": Int(scaled.size.width),
            "h": Int(scaled.size.height)
        ]
        DispatchQueue.main.async { self.preview = scaled }
        put("screen/frame", body) { [weak self] _ in
            self?.sending = false
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.isLive = false
            self.status = "انوقف البث: \(error.localizedDescription)"
        }
    }
}

struct ScreenView: View {
    @ObservedObject var model: LiveModel

    var body: some View {
        VStack(spacing: 14) {
            Text("مشاركة الشاشة المباشرة")
                .font(.title3).bold()
            Text(model.status)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            if let img = model.preview {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 380)
                    .background(Color.black)
                    .cornerRadius(10)
            } else {
                Rectangle()
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 300)
                    .cornerRadius(10)
                    .overlay(Text("لا توجد صورة بعد").foregroundColor(.secondary))
            }

            HStack(spacing: 12) {
                Button(model.isLive ? "إيقاف البث" : "تفعيل الشاشة") {
                    if model.isLive { model.stopScreen() } else { model.requestScreen() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isLive)
            }
            Spacer()
        }
        .padding()
    }
}

struct ChatView: View {
    @ObservedObject var model: LiveModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("المستخدم: ").font(.subheadline)
                Picker("الدور", selection: $model.role) {
                    Text("A").tag("A")
                    Text("B").tag("B")
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            .padding(.horizontal)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.messages) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.user == model.role ? "أنت" : m.user)
                                .font(.caption2).foregroundColor(.secondary)
                            Text(m.text).font(.body)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)
                    }
                }
                .padding()
            }

            HStack {
                TextField("اكتب رسالة…", text: $model.draft)
                    .textFieldStyle(.roundedBorder)
                Button("إرسال") { model.sendChat() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .onAppear { model.startChatPolling() }
        .onDisappear { model.stopChatPolling() }
    }
}

@main
struct MarammLiveApp: App {
    @StateObject private var model = LiveModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationView {
                    ScreenView(model: model)
                        .navigationTitle("الشاشة")
                }
                .tabItem { Label("الشاشة", systemImage: "rectangle.on.rectangle") }
                NavigationView {
                    ChatView(model: model)
                        .navigationTitle("الشات")
                }
                .tabItem { Label("الشات", systemImage: "bubble.left.and.bubble.right") }
            }
        }
    }
}

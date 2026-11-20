import SwiftUI
import UIKit
import WebKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage

private let FB_ROOT = "https://chatapp-e436f-default-rtdb.firebaseio.com/%D8%B9%D8%AF%D9%84%D9%88"
private let SITE_BASE = "https://m.maramm.workers.dev/"

// MARK: - Solid colors (no blur / no shadow / no translucency)

private extension UIColor {
    convenience init(hex: String) {
        let s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = CGFloat((v >> 16) & 0xff) / 255
        let g = CGFloat((v >> 8) & 0xff) / 255
        let b = CGFloat(v & 0xff) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - JS bridge

private let BRIDGE_JS = """
(function () {
  if (window.__marammBridgeInstalled) return;
  window.__marammBridgeInstalled = true;
  window.__marammNative = true;

  var canvas = document.createElement('canvas');
  canvas.width = 720;
  canvas.height = 1280;
  canvas.style.display = 'none';
  var ctx = canvas.getContext('2d', { alpha: false });
  var stream = null;
  var pending = null;

  function notify(action) {
    try {
      window.webkit.messageHandlers.marammNative.postMessage({ action: action });
    } catch (e) {}
  }

  function makeStream() {
    if (!stream) {
      stream = canvas.captureStream(20);
      stream.getVideoTracks().forEach(function (t) {
        var origStop = t.stop.bind(t);
        t.stop = function () { notify('stop'); origStop(); };
      });
    }
    return stream;
  }

  window.__nativeFrame = function (b64, w, h) {
    if (!b64) return;
    if (w && h && (canvas.width !== w || canvas.height !== h)) {
      canvas.width = w;
      canvas.height = h;
    }
    var img = new Image();
    img.onload = function () {
      try { ctx.drawImage(img, 0, 0, canvas.width, canvas.height); } catch (e) {}
    };
    img.src = 'data:image/jpeg;base64,' + b64;
  };

  window.__nativeReady = function () {
    if (!pending) return;
    var p = pending;
    pending = null;
    try { p.resolve(makeStream()); } catch (e) { p.reject(e); }
  };

  window.__nativeFail = function (msg) {
    if (!pending) return;
    var p = pending;
    pending = null;
    var e = new Error(msg || 'cancelled');
    e.name = 'NotAllowedError';
    p.reject(e);
  };

  window.__nativeStopped = function () {
    stream = null;
  };

  var md = navigator.mediaDevices;
  if (!md) {
    md = {};
    try { Object.defineProperty(navigator, 'mediaDevices', { value: md, configurable: true }); } catch (e) {}
  }
  if (md) {
    Object.defineProperty(md, 'getDisplayMedia', {
      configurable: true,
      value: function () {
        return new Promise(function (resolve, reject) {
          pending = { resolve: resolve, reject: reject };
          notify('start');
        });
      }
    });
  }
})();
"""

private final class NativeBridge: NSObject, WKScriptMessageHandler {
    weak var owner: LiveViewController?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        DispatchQueue.main.async {
            switch action {
            case "start": self.owner?.startNativeCapture()
            case "stop": self.owner?.stopNativeCapture()
            default: break
            }
        }
    }
}

// MARK: - Main controller

final class LiveViewController: UIViewController,
                                SCContentSharingPickerObserver,
                                SCStreamOutput,
                                SCStreamDelegate {

    private var webView: WKWebView!
    private let bridge = NativeBridge()

    private var stream: SCStream?
    private var pickerAdded = false
    private var sendingToJS = false
    private var lastJSSent = Date.distantPast
    private var lastFirebaseSent = Date.distantPast
    private let ciContext = CIContext()

    override func viewDidLoad() {
        super.viewDidLoad()
        bridge.owner = self
        view.backgroundColor = UIColor(hex: "#17181f")

        let contentController = WKUserContentController()
        contentController.add(bridge, name: "marammNative")
        contentController.addUserScript(
            WKUserScript(source: BRIDGE_JS,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true)
        )

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences?.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = true
        webView.backgroundColor = UIColor(hex: "#17181f")
        webView.scrollView.backgroundColor = UIColor(hex: "#17181f")
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(webView)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            webView.topAnchor.constraint(equalTo: guide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
        ])

        loadPage()
    }

    private func loadPage() {
        guard let path = Bundle.main.path(forResource: "index", ofType: "html"),
              let html = try? String(contentsOfFile: path, encoding: .utf8) else {
            if let url = URL(string: SITE_BASE) {
                webView.load(URLRequest(url: url))
            }
            return
        }
        webView.loadHTMLString(html, baseURL: URL(string: SITE_BASE))
    }

    func startNativeCapture() {
        if stream != nil {
            evalJS("window.__nativeReady && window.__nativeReady()")
            return
        }
        let picker = SCContentSharingPicker.shared
        if !pickerAdded {
            picker.add(self)
            pickerAdded = true
        }
        picker.isActive = true
        picker.present()
    }

    func stopNativeCapture() {
        try? stream?.stopCapture()
        stream = nil
        sendingToJS = false
        evalJS("window.__nativeStopped && window.__nativeStopped()")
    }

    private func startStream(with filter: SCContentFilter) {
        let cfg = SCStreamConfiguration()
        cfg.width = 720
        cfg.height = 1280
        cfg.capturesAudio = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue.global(qos: .utility))
            try s.startCapture()
            DispatchQueue.main.async {
                self.stream = s
                self.evalJS("window.__nativeReady && window.__nativeReady()")
            }
        } catch {
            DispatchQueue.main.async {
                self.evalJS("window.__nativeFail && window.__nativeFail('start-error')")
            }
        }
    }

    private func evalJS(_ script: String) {
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker,
                              didUpdateWith filter: SCContentFilter,
                              for stream: SCStream?) {
        startStream(with: filter)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker,
                              didCancelFor stream: SCStream?) {
        evalJS("window.__nativeFail && window.__nativeFail('cancel')")
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        evalJS("window.__nativeFail && window.__nativeFail('picker-error')")
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard !sendingToJS else { return }
        let now = Date()
        guard now.timeIntervalSince(lastJSSent) >= 0.05 else { return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ci = CIImage(cvImageBuffer: buffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let raw = UIImage(cgImage: cg)

        let scale = min(720 / raw.size.width, 1280 / raw.size.height, 1.0)
        let target = CGSize(width: floor(raw.size.width * scale),
                            height: floor(raw.size.height * scale))
        let img = raw.preparingThumbnail(of: target) ?? raw
        guard let jpeg = img.jpegData(compressionQuality: 0.45) else { return }

        sendingToJS = true
        lastJSSent = now
        let b64 = jpeg.base64EncodedString()
        let w = Int(img.size.width)
        let h = Int(img.size.height)

        evalJS("window.__nativeFrame && window.__nativeFrame('\(b64)',\(w),\(h))")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.sendingToJS = false
        }

        if now.timeIntervalSince(lastFirebaseSent) >= 0.4 {
            lastFirebaseSent = now
            put("screen/frame", [
                "b64": b64,
                "t": Int(now.timeIntervalSince1970 * 1000),
                "w": w,
                "h": h
            ])
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.stream = nil
            self.evalJS("window.__nativeStopped && window.__nativeStopped()")
            self.evalJS("window.__nativeFail && window.__nativeFail('stream-stopped')")
        }
    }

    private func put(_ path: String, _ object: [String: Any]) {
        guard let url = URL(string: FB_ROOT + "/" + path + ".json") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: object, options: [])
        URLSession.shared.dataTask(with: req).resume()
    }
}

struct WebViewContainer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> LiveViewController {
        LiveViewController()
    }

    func updateUIViewController(_ uiViewController: LiveViewController, context: Context) {}
}

@main
struct MarammLiveApp: App {
    var body: some Scene {
        WindowGroup {
            WebViewContainer()
        }
    }
}

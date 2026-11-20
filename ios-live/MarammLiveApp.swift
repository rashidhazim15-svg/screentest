import SwiftUI
import UIKit
import WebKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage
import UserNotifications

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

// MARK: - JS bridge: offline-light + native screen capture + notifications

private let BRIDGE_JS = """
(function () {
  if (window.__marammBridgeInstalled) return;
  window.__marammBridgeInstalled = true;
  window.__marammNative = true;

  /* ---- 1) Kill non-essential internet requests inside the app ---------- */
  var BLOCK = [
    'fonts.googleapis.com', 'fonts.gstatic.com', 'www.gstatic.com',
    'manifest.webmanifest', 'icon-192.png', 'icon-512.png', 'apple-touch-icon.png',
    'api.deezer.com', 'itunes.apple.com',
    'image.pollinations.ai', 'text.pollinations.ai',
    'ntfy.sh', 'api.telegram.org',
    'sw.js'
  ];
  function blocked(u) {
    u = String(u || '');
    for (var i = 0; i < BLOCK.length; i++) if (u.indexOf(BLOCK[i]) >= 0) return true;
    return false;
  }
  var BLANK_GIF = 'data:image/gif;base64,R0lGODlhAQABAAD/ACwAAAAAAQABAAACADs=';

  var realFetch = window.fetch;
  window.fetch = function (input, init) {
    var u = typeof input === 'string' ? input : ((input && input.url) || '');
    if (blocked(u)) return Promise.reject(new Error('blocked in native app'));
    return realFetch.apply(this, arguments);
  };

  var realOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    var args = Array.prototype.slice.call(arguments);
    if (blocked(url)) args[1] = 'data:text/plain,';
    return realOpen.apply(this, args);
  };

  try {
    var imgDesc = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
    Object.defineProperty(HTMLImageElement.prototype, 'src', {
      configurable: true,
      get: function () { return imgDesc.get.call(this); },
      set: function (v) { imgDesc.set.call(this, blocked(v) ? BLANK_GIF : v); }
    });
    var scriptDesc = Object.getOwnPropertyDescriptor(HTMLScriptElement.prototype, 'src');
    Object.defineProperty(HTMLScriptElement.prototype, 'src', {
      configurable: true,
      get: function () { return scriptDesc.get.call(this); },
      set: function (v) { scriptDesc.set.call(this, blocked(v) ? 'data:text/javascript,' : v); }
    });
  } catch (e) {}

  try {
    var mo = new MutationObserver(function (list) {
      list.forEach(function (m) {
        (m.addedNodes || []).forEach(function (n) {
          if (!n || n.nodeType !== 1) return;
          var tag = n.tagName.toLowerCase();
          var v = '';
          if (tag === 'img' || tag === 'script') v = n.src || '';
          else if (tag === 'link') v = n.href || '';
          if (v && blocked(v) && n.remove) n.remove();
        });
      });
    });
    mo.observe(document.documentElement, { childList: true, subtree: true });
  } catch (e) {}

  /* Service worker is disabled; native local notifications replace push. */
  try {
    Object.defineProperty(navigator, 'serviceWorker', {
      configurable: true,
      value: {
        register: function () { return Promise.reject(new Error('disabled')); },
        addEventListener: function () {},
        removeEventListener: function () {},
        ready: new Promise(function () {})
      }
    });
  } catch (e) {}

  /* ---- 2) Full-screen layout with safe-area inset for the status bar ---- */
  var style = document.createElement('style');
  style.textContent = [
    'html,body{margin:0!important;padding:0!important;background:#0d0f14!important;overflow:hidden!important;}',
    '#chatBox{top:env(safe-area-inset-top,0px)!important;bottom:env(safe-area-inset-bottom,0px)!important;left:0!important;right:0!important;width:100vw!important;height:auto!important;}',
    '#chatBox.match{top:env(safe-area-inset-top,0px)!important;bottom:env(safe-area-inset-bottom,0px)!important;height:auto!important;}',
    '#chatSettings,#devPanel,#imgViewer,#allMediaModal{top:env(safe-area-inset-top,0px)!important;bottom:env(safe-area-inset-bottom,0px)!important;height:auto!important;}'
  ].join('');
  (document.head || document.documentElement).appendChild(style);

  /* ---- 3) Native screen-capture bridge -------------------------------- */
  var canvas = document.createElement('canvas');
  canvas.width = 640;
  canvas.height = 1136;
  canvas.style.display = 'none';
  var ctx = canvas.getContext('2d', { alpha: false });
  var stream = null;
  var pending = null;

  function notify(action, extra) {
    try {
      var msg = { action: action };
      if (extra) msg.body = extra;
      window.webkit.messageHandlers.marammNative.postMessage(msg);
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

  window.__nativeStopped = function () { stream = null; };

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
            case "notify": self.owner?.notify(body: body["body"] as? String)
            default: break
            }
        }
    }
}

// MARK: - Main controller

final class LiveViewController: UIViewController,
                                SCContentSharingPickerObserver,
                                SCStreamOutput,
                                SCStreamDelegate,
                                UNUserNotificationCenterDelegate {

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
        view.backgroundColor = UIColor(hex: "#0d0f14")

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

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
        webView.backgroundColor = UIColor(hex: "#0d0f14")
        webView.scrollView.backgroundColor = UIColor(hex: "#0d0f14")
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
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

    // MARK: - Notifications

    func notify(body: String?) {
        let text = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "رسالة جديدة"
        content.body = String(text.prefix(160))
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Native screen capture

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
        cfg.width = 640
        cfg.height = 1136
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
        guard now.timeIntervalSince(lastJSSent) >= 0.065 else { return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ci = CIImage(cvImageBuffer: buffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let raw = UIImage(cgImage: cg)

        let scale = min(640 / raw.size.width, 1136 / raw.size.height, 1.0)
        let target = CGSize(width: floor(raw.size.width * scale),
                            height: floor(raw.size.height * scale))
        let img = raw.preparingThumbnail(of: target) ?? raw
        guard let jpeg = img.jpegData(compressionQuality: 0.40) else { return }

        sendingToJS = true
        lastJSSent = now
        let b64 = jpeg.base64EncodedString()
        let w = Int(img.size.width)
        let h = Int(img.size.height)

        evalJS("window.__nativeFrame && window.__nativeFrame('\(b64)',\(w),\(h))")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.sendingToJS = false
        }

        if now.timeIntervalSince(lastFirebaseSent) >= 0.6 {
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

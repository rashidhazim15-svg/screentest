import SwiftUI
import UIKit
import WebKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage
import AudioToolbox
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
    /* www.gstatic.com is NOT blocked: Firebase SDK scripts are served from
       there. Blocking it made `firebase` undefined and aborted the whole page
       script, so the chat button never worked. Only the font host is blocked. */
    'fonts.googleapis.com', 'fonts.gstatic.com',
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

  /* ---- 2) Full-screen page, safe-area respected by the content ---------- */
  var style = document.createElement('style');
  style.textContent = [
    'html,body{margin:0!important;padding:0!important;background:#0d0f14!important;overflow:hidden!important;}',
    /* :not(.kb) is essential: while the keyboard is open applyViewport() pins
       #chatBox to the visual viewport with INLINE top/height. A blanket
       !important rule here would override those inline values and break the
       island-follows-keyboard behaviour. */
    '#chatBox:not(.kb){top:0!important;bottom:0!important;left:0!important;right:0!important;width:100vw!important;height:100dvh!important;}',
    '#chatBox.match:not(.kb){top:0!important;bottom:0!important;left:0!important;right:0!important;width:100vw!important;height:100dvh!important;}',
    '#chatBox.cinema:not(.kb) #watchSection{top:env(safe-area-inset-top,0px)!important;bottom:env(safe-area-inset-bottom,0px)!important;height:auto!important;}',
    '#chatSettings,#devPanel,#imgViewer,#allMediaModal{top:0!important;bottom:0!important;height:100dvh!important;}'
  ].join('');
  (document.head || document.documentElement).appendChild(style);

  /* ---- 3) Native screen-capture bridge -------------------------------- */
  var canvas = document.createElement('canvas');
  /* Match the phone's real aspect ratio. The native bridge replaces these
     with the exact safe-area size once the first captured frame arrives. */
  var capW = 640;
  var capH = Math.max(2, Math.round(capW * (window.innerHeight / Math.max(1, window.innerWidth)) / 2) * 2);
  canvas.width = capW;
  canvas.height = capH;
  canvas.style.display = 'none';
  var ctx = canvas.getContext('2d', { alpha: false });
  var stream = null;
  var pending = null;

  /* ---- 3b) Native PCM audio -> real MediaStreamTrack ------------------ */
  var audioCtx = null;
  var audioDest = null;
  var audioProc = null;
  var audioQueue = [];
  var audioRate = 48000;
  var audioChannels = 2;

  function ensureAudio() {
    if (audioCtx) return audioDest;
    try {
      var AC = window.AudioContext || window.webkitAudioContext;
      audioCtx = new AC();
      audioDest = audioCtx.createMediaStreamDestination();
      audioProc = audioCtx.createScriptProcessor(4096, audioChannels, audioChannels);
      audioProc.onaudioprocess = function (e) {
        var chans = [];
        for (var c = 0; c < audioChannels; c++) chans.push(e.outputBuffer.getChannelData(c));
        var n = chans.length ? chans[0].length : 0;
        for (var i = 0; i < n; i++) {
          var frame = audioQueue.shift();
          for (var c2 = 0; c2 < chans.length; c2++) chans[c2][i] = frame ? (frame[c2] || 0) : 0;
        }
      };
      var silent = audioCtx.createGain();
      silent.gain.value = 0;
      audioProc.connect(audioDest);
      audioProc.connect(silent);
      silent.connect(audioCtx.destination);
    } catch (e) {
      audioCtx = null; audioDest = null; audioProc = null;
    }
    return audioDest;
  }

  window.__nativeAudio = function (b64, rate, channels) {
    if (!b64) return;
    try {
      var bin = atob(b64);
      var bytes = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      var pcm = new Float32Array(bytes.buffer, 0, Math.floor(bytes.length / 4));
      if (rate) audioRate = rate;
      if (channels) audioChannels = channels;
      if (!audioCtx) ensureAudio();
      if (!audioDest) return;
      var frames = Math.floor(pcm.length / audioChannels);
      for (var f = 0; f < frames; f++) {
        var item = [];
        for (var c = 0; c < audioChannels; c++) item.push(pcm[f * audioChannels + c]);
        audioQueue.push(item);
      }
      if (audioQueue.length > 240) audioQueue.splice(0, audioQueue.length - 240);
      if (audioCtx && audioCtx.state === 'suspended') audioCtx.resume();
    } catch (e) {}
  };

  function notify(action, extra) {
    try {
      var msg = { action: action };
      if (extra) msg.body = extra;
      window.webkit.messageHandlers.marammNative.postMessage(msg);
    } catch (e) {}
  }

  function makeStream() {
    if (!stream) {
      stream = canvas.captureStream(16);
      var ad = ensureAudio();
      if (ad) {
        var ats = ad.stream.getAudioTracks();
        if (ats.length) stream.addTrack(ats[0]);
      }
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

  window.__nativeStopped = function () { stream = null; audioQueue.length = 0; };

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
    private var lastAudioSent = Date.distantPast
    private var lastFirebaseSent = Date.distantPast
    private let ciContext = CIContext()
    /// Cached on the main thread; the frame handler runs on a background queue.
    private var stageSize = CGSize(width: 640, height: 1136)

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

        // Edge-to-edge: the page itself applies safe-area insets, so there are
        // no black native strips above/below the chat.
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        loadPage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard webView != nil else { return }
        let insets = webView.safeAreaInsets
        let w = max(1, webView.bounds.width - insets.left - insets.right)
        let h = max(1, webView.bounds.height - insets.top - insets.bottom)
        let scale = min(640 / w, 1.0)
        var size = CGSize(width: floor(w * scale), height: floor(h * scale))
        size.width = floor(size.width / 2) * 2
        size.height = floor(size.height / 2) * 2
        stageSize = CGSize(width: max(2, size.width), height: max(2, size.height))
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

    /// The exact size of the chat stage (cached from viewDidLayoutSubviews,
    /// because the frame handler runs off the main thread). Matching this to
    /// the viewer removes the letterbox gaps around the shared screen.
    private func captureSize() -> CGSize { stageSize }

    private func startStream(with filter: SCContentFilter) {
        let cfg = SCStreamConfiguration()
        let size = captureSize()
        cfg.width = Int(size.width)
        cfg.height = Int(size.height)
        cfg.capturesAudio = true

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue.global(qos: .utility))
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue.global(qos: .utility))
            s.startCapture()
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

    // MARK: - Picker observer

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

    // MARK: - Frame output (balanced quality for weak links)

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        if type == .audio { handleAudio(sampleBuffer); return }
        guard type == .screen else { return }
        guard !sendingToJS else { return }
        let now = Date()
        guard now.timeIntervalSince(lastJSSent) >= 0.065 else { return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ci = CIImage(cvImageBuffer: buffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let raw = UIImage(cgImage: cg)

        let size = captureSize()
        let scale = min(size.width / raw.size.width, size.height / raw.size.height, 1.0)
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

    /// ScreenCaptureKit audio is delivered as native-endian PCM. Forward it to
    /// the page as Float32 frames so the existing WebRTC peers carry real sound.
    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastAudioSent) >= 0.05 else { return }
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { return }
        let rate = max(1, Int(asbd.mSampleRate))
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bits = Int(asbd.mBitsPerChannel)
        guard (isFloat && bits == 32) || (!isFloat && bits == 16) else { return }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // Read the PCM planes straight from the block buffer. This avoids the
        // AudioBufferList helpers that are unavailable on iOS.
        var totalLength = 0
        var dataPtr: UnsafeMutablePointer<Int8>? = nil
        let status = CMBlockBufferGetDataPointer(block, atOffset: 0,
                                                 lengthAtOffsetOut: nil,
                                                 totalLengthOut: &totalLength,
                                                 dataPointerOut: &dataPtr)
        guard status == noErr, let ptr = dataPtr else { return }

        let bytesPerSample = isFloat ? 4 : 2
        let planeSamples = min(frames, totalLength / bytesPerSample / max(1, channels))
        guard planeSamples > 0 else { return }
        var pcm = [Float32](repeating: 0, count: planeSamples * channels)
        let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

        if interleaved {
            if isFloat {
                let p = ptr.assumingMemoryBound(to: Float32.self)
                for i in 0..<(planeSamples * channels) { pcm[i] = p[i] }
            } else {
                let p = ptr.assumingMemoryBound(to: Int16.self)
                for i in 0..<(planeSamples * channels) { pcm[i] = Float32(p[i]) / 32768.0 }
            }
        } else {
            let planeBytes = planeSamples * bytesPerSample
            for c in 0..<channels {
                let offset = c * planeBytes
                guard offset + planeBytes <= totalLength else { break }
                let cp = ptr.advanced(by: offset)
                if isFloat {
                    let p = cp.assumingMemoryBound(to: Float32.self)
                    for i in 0..<planeSamples { pcm[i * channels + c] = p[i] }
                } else {
                    let p = cp.assumingMemoryBound(to: Int16.self)
                    for i in 0..<planeSamples { pcm[i * channels + c] = Float32(p[i]) / 32768.0 }
                }
            }
        }

        lastAudioSent = now
        let data = pcm.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
        let b64 = data.base64EncodedString()
        evalJS("window.__nativeAudio && window.__nativeAudio('\(b64)',\(rate),\(channels))")
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.stream = nil
            self.evalJS("window.__nativeStopped && window.__nativeStopped()")
            self.evalJS("window.__nativeFail && window.__nativeFail('stream-stopped')")
        }
    }

    // MARK: - Firebase fallback frame path (simple viewer compatibility)

    private func put(_ path: String, _ object: [String: Any]) {
        guard let url = URL(string: FB_ROOT + "/" + path + ".json") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: object, options: [])
        URLSession.shared.dataTask(with: req).resume()
    }
}

// MARK: - SwiftUI wrapper

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

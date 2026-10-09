import Foundation
import AppKit
import WebKit

// MARK: - ZCode 阿里云无痕验证码（WebKit 原生实现）
/// 复刻原版 Edge CDP 流程：加载 AliyunCaptcha，自动发起无痕验证，
/// 成功回调写入 window.__P（verifyParam）；滑块升级时窗口可见，可手动完成。
final class ZcodeCaptcha {
    static let shared = ZcodeCaptcha()
    private var active: [CaptchaController] = []
    private let lock = NSLock()

    func solve(region: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.main.async {
                let c = CaptchaController(region: region, cont: cont)
                self.lock.lock(); self.active.append(c); self.lock.unlock()
                c.start()
            }
        }
    }

    fileprivate func release(_ c: CaptchaController) {
        lock.lock()
        active.removeAll { $0 === c }
        lock.unlock()
    }
}

private final class CaptchaController: NSObject {
    typealias Cont = CheckedContinuation<String, Error>
    let region: String
    let cont: Cont
    var win: NSWindow?
    var webView: WKWebView?
    var timer: Timer?
    var deadline: Date = .distantPast
    var finished = false

    init(region: String, cont: Cont) {
        self.region = region
        self.cont = cont
        super.init()
    }

    func start() {
        let config = WKWebViewConfiguration()
        if #available(macOS 11.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        } else {
            config.preferences.javaScriptEnabled = true
        }
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 640), configuration: config)
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground") // 透明背景更贴合托盘窗口
        self.webView = wv

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 660),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "ZCode 验证码 · \(region)"
        win.contentView = wv
        win.center()
        win.makeKeyAndOrderFront(nil)
        self.win = win

        deadline = Date().addingTimeInterval(180) // 3 分钟超时
        wv.loadHTMLString(buildHTML(), baseURL: URL(string: "https://zcode.z.ai/"))

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard !finished else { return }
        if Date() > deadline {
            finish(throwing: NSError(domain: "ZcodeCaptcha", code: -1,
                                     userInfo: [NSLocalizedDescriptionKey: "验证码超时：风控升级为滑块且未在 3 分钟内完成"]))
            return
        }
        Task { [weak self] in await self?.poll() }
    }

    private func poll() async {
        guard let wv = webView, !finished else { return }
        let expr = "JSON.stringify((function(){var f=document.querySelector('iframe');return {p:window.__P,e:window.__E,ifr:f?1:0};})())"
        guard let res = try? await wv.evaluateJavaScript(expr) as? String,
              let d = J.dict(res) else { return }
        if let p = J.str(d, "p"), !p.isEmpty {
            finish(returning: p)
        } else if let e = J.str(d, "e"), !e.isEmpty, !e.contains("F001") {
            finish(throwing: NSError(domain: "ZcodeCaptcha", code: -1,
                                     userInfo: [NSLocalizedDescriptionKey: "验证码失败：\(e)"]))
        }
    }

    private func finish(returning s: String) {
        guard !finished else { return }
        finished = true
        cleanup()
        cont.resume(returning: s)
    }

    private func finish(throwing e: Error) {
        guard !finished else { return }
        finished = true
        cleanup()
        cont.resume(throwing: e)
    }

    private func cleanup() {
        timer?.invalidate(); timer = nil
        webView?.stopLoading()
        webView = nil
        win?.close(); win = nil
        ZcodeCaptcha.shared.release(self)
    }

    // MARK: 验证码 HTML（与官方 client/configs 默认值一致；失败回退社区实测值）
    private func buildHTML() -> String {
        let (scene, prefix) = fetchConfig()
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>TraeSign</title></head><body>
        <div id="cap"></div><button id="btn">go</button>
        <script src="https://o.alicdn.com/captcha-frontend/aliyunCaptcha/AliyunCaptcha.js"></script>
        <script>
        window.__P=null;window.__E=null;
        (function t(){
          if(typeof initAliyunCaptcha!=="function"){setTimeout(t,200);return}
          setTimeout(function(){
            initAliyunCaptcha({
              SceneId:"\(scene)",mode:"popup",region:"\(region)",prefix:"\(prefix)",
              language:"zh-cn",element:"#cap",button:"#btn",
              getInstance:function(i){(i.startTracelessVerification||i.show).call(i)},
              success:function(r){window.__P=(typeof r==="string")?r:((r&&r.captchaVerifyParam)||JSON.stringify(r))},
              fail:function(e){window.__E="fail:"+JSON.stringify(e)},
              onError:function(e){window.__E="onError:"+JSON.stringify(e)}
            });
          }, 600+Math.floor(Math.random()*1400));
        })();
        </script></body></html>
        """
    }

    /// 同步拉取 client/configs 的 sceneId/prefix（5s 超时，失败用默认值）
    private func fetchConfig() -> (String, String) {
        let url = URL(string: "\(ZcodeEngine.baseURL)/client/configs?app_version=\(ZcodeEngine.appVersion)")!
        var scene = "11xygtvd", prefix = "no8xfe"
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "GET"
        let task = URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let d = J.dict(String(data: data, encoding: .utf8) ?? ""),
               let cfg = J.innerDict(J.innerDict(J.innerDict(d, "data"), "configs"), "captcha") {
                if let s = J.str(cfg, "sceneId"), !s.isEmpty { scene = s }
                if let p = J.str(cfg, "prefix"), !p.isEmpty { prefix = p }
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 6)
        return (scene, prefix)
    }
}

extension CaptchaController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.write("captcha: 加载失败 \(error.localizedDescription)")
    }
}

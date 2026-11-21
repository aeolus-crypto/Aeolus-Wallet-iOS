import Foundation
import UIKit
import WebKit
import Capacitor

/// The iOS counterpart of the Android activity's extras, so index.html runs unchanged:
///  - window.Android: biometric unlock, sensitive clipboard copy and "Delete wallet" wipe
///    (Android: WalletBridge), injected before the page's own scripts run;
///  - window.AndroidSettings.openAppSettings (the QR scanner uses the WebView camera on iOS);
///  - privacy shield (Android: FLAG_SECURE): a cover over the app in the app switcher and while
///    the screen is recorded or mirrored. iOS lets no app block screenshots themselves.
/// Android's JavaScript interface answers synchronously; WebKit's message handlers do not. So the
/// read-only answers (biometric available / enabled) are kept in the page and refreshed by
/// native code, and the commands are posted as messages.
@objc(AeolusShellPlugin)
public class AeolusShellPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "AeolusShellPlugin"
    public let jsName = "AeolusShell"
    public let pluginMethods: [CAPPluginMethod] = []

    private static let handlerName = "aeolusAndroid"
    private var cover: UIView?
    private var inactive = false

    override public func load() {
        InstallGuard.run()
        DispatchQueue.main.async { [weak self] in self?.setUp() }
    }

    private func setUp() {
        guard let web = bridge?.webView else { return }
        let ucc = web.configuration.userContentController
        ucc.add(WeakHandler(self), name: Self.handlerName)
        let script = WKUserScript(source: Self.pageScript(bioAvailable: Biometric.available, bioEnabled: Biometric.enabled),
                                  injectionTime: .atDocumentStart, forMainFrameOnly: true)
        ucc.addUserScript(script)
        // in case the first page load had already begun when the plugin loaded
        web.evaluateJavaScript(script.source, completionHandler: nil)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(resignActive), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(becomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(captureChanged), name: UIScreen.capturedDidChangeNotification, object: nil)
        captureChanged()
    }

    // MARK: - page bridge

    private static func pageScript(bioAvailable: Bool, bioEnabled: Bool) -> String {
        """
        (function(){
          if (window.Android && window.Android.__aeolus) return;
          var st = { a: \(bioAvailable), e: \(bioEnabled) };
          function post(m){ try{ window.webkit.messageHandlers.\(handlerName).postMessage(m); }catch(e){} }
          window.Android = {
            __aeolus: true,
            isBiometricAvailable: function(){ return st.a; },
            isBiometricEnabled: function(){ return st.a && st.e; },
            setBiometricEnabled: function(on){ st.e = !!on; post({ cmd: 'setBiometricEnabled', on: !!on }); },
            showBiometricPrompt: function(){ post({ cmd: 'showBiometricPrompt' }); },
            copySensitive: function(t){ if (!t) return false; post({ cmd: 'copySensitive', text: String(t) }); return true; },
            clearWalletCache: function(){ post({ cmd: 'clearWalletCache' }); },
            updateBalances: function(){}, updateSyncStatus: function(){}, updateTransactions: function(){}
          };
          window.AndroidSettings = { openAppSettings: function(){ post({ cmd: 'openAppSettings' }); } };
          window.__aeolusSetBio = function(a, e){ st.a = !!a; st.e = !!e; };
        })();
        """
    }

    fileprivate func handle(_ message: WKScriptMessage) {
        // Only the app's own page, in the main frame.
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == bridge?.config.localURL.scheme,
              let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "setBiometricEnabled":
            Biometric.setEnabled((body["on"] as? Bool) ?? false)
            refreshBio()
        case "showBiometricPrompt":
            Biometric.prompt { [weak self] outcome in
                switch outcome {
                case .ok: self?.bioResult(true, nil)
                case .failed: self?.bioResult(false, nil)
                case .invalidated:
                    self?.refreshBio()
                    self?.bioResult(false, "invalidated")
                }
            }
        case "copySensitive":
            if let t = body["text"] as? String, !t.isEmpty {
                // local only (no Universal Clipboard), gone after 60 s
                UIPasteboard.general.setItems([["public.utf8-plain-text": t]],
                                              options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
            }
        case "clearWalletCache":
            ZephyrWalletPlugin.wipeFromNative()
        case "openAppSettings":
            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
        default:
            break
        }
    }

    private func bioResult(_ ok: Bool, _ reason: String?) {
        let arg = reason.map { ",'\($0)'" } ?? ""
        bridge?.webView?.evaluateJavaScript("try{window._onBioResult(\(ok)\(arg))}catch(e){}", completionHandler: nil)
    }

    private func refreshBio() {
        bridge?.webView?.evaluateJavaScript(
            "try{window.__aeolusSetBio(\(Biometric.available),\(Biometric.enabled))}catch(e){}", completionHandler: nil)
    }

    // MARK: - privacy shield

    @objc private func resignActive() { inactive = true; updateCover() }
    @objc private func becomeActive() { inactive = false; updateCover() }
    @objc private func captureChanged() { updateCover() }

    private func updateCover() {
        guard let window = bridge?.viewController?.view.window else { return }
        let captured = window.windowScene?.screen.isCaptured ?? UIScreen.main.isCaptured
        if inactive || captured {
            if cover == nil {
                let v = UIView(frame: window.bounds)
                v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                v.backgroundColor = .black
                let label = UILabel()
                label.text = "Aeolus"
                label.textColor = .white
                label.font = .systemFont(ofSize: 28, weight: .semibold)
                label.translatesAutoresizingMaskIntoConstraints = false
                v.addSubview(label)
                NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                                             label.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
                window.addSubview(v)
                cover = v
            }
        } else {
            cover?.removeFromSuperview()
            cover = nil
        }
    }
}

/// WKUserContentController keeps its handlers strongly; this keeps the plugin out of that cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: AeolusShellPlugin?
    init(_ t: AeolusShellPlugin) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handle(message)
    }
}

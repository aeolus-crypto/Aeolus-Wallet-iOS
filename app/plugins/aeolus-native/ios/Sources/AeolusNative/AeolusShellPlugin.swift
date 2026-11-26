import Foundation
import MessageUI
import UIKit
import WebKit
import Capacitor

/// The iOS counterpart of the Android activity's extras, so index.html runs unchanged:
///  - window.Android: biometric unlock, sensitive clipboard copy and "Delete wallet" wipe
///    (Android: WalletBridge), injected before the page's own scripts run;
///  - window.Android.emailDebugLog (Settings -> Email Debug Log): Mail, or the share sheet;
///  - window.AndroidSettings.openAppSettings (the QR scanner uses the WebView camera on iOS);
///  - Background Sync / Payment Alerts rows stay visible; their note text is replaced with the iOS one;
///  - the WebView may use the camera (QR scanner) and nothing else: no microphone;
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
    static let debugLogAddress = "aeoluswallet@protonmail.com"
    private var cover: UIView?
    private var inactive = false
    private var mediaGuard: MediaGuard?
    private var mailDelegate: MailDelegate?

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
        let layout = WKUserScript(source: Self.safeAreaScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        ucc.addUserScript(layout)
        // Camera only (Android: onPermissionRequest grants VIDEO_CAPTURE and denies the rest).
        let g = MediaGuard(forwardingTo: web.uiDelegate, appScheme: bridge?.config.localURL.scheme)
        mediaGuard = g
        web.uiDelegate = g
        // in case the first page load had already begun when the plugin loaded
        web.evaluateJavaScript(script.source, completionHandler: nil)
        web.evaluateJavaScript(layout.source, completionHandler: nil)

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
            emailDebugLog: function(t){ post({ cmd: 'emailDebugLog', text: String(t || '') }); return true; },
            updateBalances: function(){}, updateSyncStatus: function(){}, updateTransactions: function(){}
          };
          window.AndroidSettings = { openAppSettings: function(){ post({ cmd: 'openAppSettings' }); } };
          window.__aeolusSetBio = function(a, e){ st.a = !!a; st.e = !!e; };
        })();
        """
    }

    /// Keeps the page clear of the notch / Dynamic Island and the home indicator. The web view
    /// is edge to edge on iOS (Android lays the page out below its status bar instead), so the
    /// page opts in to the safe-area insets and every full-screen layer stays inside them:
    /// pages start below the notch and end above the home bar; the bottom tab bar keeps its
    /// background under the home bar. index.html itself stays the same as on Android.
    private static let safeAreaScript = """
        (function(){
          if (document.getElementById('aeolus-ios-safe-area')) return;
          var m = document.querySelector('meta[name=viewport]');
          if (m && m.content.indexOf('viewport-fit') < 0) m.content += ',viewport-fit=cover';
          var t = 'env(safe-area-inset-top)', b = 'env(safe-area-inset-bottom)';
          var s = document.createElement('style');
          s.id = 'aeolus-ios-safe-area';
          s.textContent =
            'html,body{background:#080B14}' +
            '#app{max-width:100%;max-height:none}' +
            '.page{top:' + t + ';bottom:' + b + '}' +
            '#bnav{padding-bottom:calc(8px + ' + b + ')}' +
            '#page-home,#page-history,#page-settings,#page-node,#page-swap{bottom:0;padding-bottom:calc(56px + ' + b + ')}' +
            '#send-confirm-modal{padding-top:calc(24px + ' + t + ') !important;padding-bottom:calc(24px + ' + b + ') !important}' +
            '#qr-scanner-modal,#wipe-confirm-modal,#cam-perm-modal{padding-top:' + t + ' !important;padding-bottom:' + b + ' !important}';
          (document.head || document.documentElement).appendChild(s);
          // Background Sync works differently here (iOS wakes the app now and then, there is no always-on
          // service), so the page's Android battery tip is replaced by what is true on iOS.
          var note = document.getElementById('bgsync-note');
          if (note) note.textContent = 'iOS decides when this runs: roughly every 15 minutes to a few hours. Needs Background App Refresh on and Low Power Mode off, and stops if you swipe the app away.';
        })();
        """

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
        case "emailDebugLog":
            emailDebugLog((body["text"] as? String) ?? "")
        case "openAppSettings":
            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
        default:
            break
        }
    }

    /// Mail with the address, subject and log filled in (nothing is sent until the user taps Send);
    /// without a Mail account, the share sheet with the log as a text file. Last 200k characters,
    /// as on Android.
    private func emailDebugLog(_ text: String) {
        let log = text.count > 200_000 ? String(text.suffix(200_000)) : text
        guard let vc = bridge?.viewController else { return }
        let subject = "Aeolus Wallet debug log"
        if MFMailComposeViewController.canSendMail() {
            let m = MFMailComposeViewController()
            let d = MailDelegate()
            mailDelegate = d
            m.mailComposeDelegate = d
            m.setToRecipients([Self.debugLogAddress])
            m.setSubject(subject)
            m.setMessageBody(log, isHTML: false)
            vc.present(m, animated: true)
            return
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Aeolus-debug-log.txt")
        do {
            try Data(log.utf8).write(to: file, options: [.atomic, .completeFileProtection])
        } catch {
            return
        }
        let share = UIActivityViewController(activityItems: [DebugLogItem(file: file, subject: subject)],
                                             applicationActivities: nil)
        share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: file) }
        share.popoverPresentationController?.sourceView = vc.view
        vc.present(share, animated: true)
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

/// Grants the page's camera request (QR scanner) and denies anything with the microphone; every
/// other WKUIDelegate call goes on to Capacitor's own delegate.
private final class MediaGuard: NSObject, WKUIDelegate {
    private weak var next: WKUIDelegate?
    private let appScheme: String?

    init(forwardingTo next: WKUIDelegate?, appScheme: String?) {
        self.next = next
        self.appScheme = appScheme
    }

    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let ownPage = frame.isMainFrame && origin.protocol == appScheme
        decisionHandler(ownPage && type == .camera ? .grant : .deny)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (next?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if super.responds(to: aSelector) { return nil }
        return next
    }
}

private final class MailDelegate: NSObject, MFMailComposeViewControllerDelegate {
    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult,
                               error: Error?) {
        controller.dismiss(animated: true)
    }
}

/// The share sheet's item: the log file, with the email subject for mail apps.
private final class DebugLogItem: NSObject, UIActivityItemSource {
    let file: URL
    let subject: String
    init(file: URL, subject: String) { self.file = file; self.subject = subject }
    func activityViewControllerPlaceholderItem(_ c: UIActivityViewController) -> Any { file }
    func activityViewController(_ c: UIActivityViewController, itemForActivityType t: UIActivity.ActivityType?) -> Any? { file }
    func activityViewController(_ c: UIActivityViewController, subjectForActivityType t: UIActivity.ActivityType?) -> String { subject }
}

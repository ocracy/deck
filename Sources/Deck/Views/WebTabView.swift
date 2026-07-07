import SwiftUI
import AppKit
import WebKit

// MARK: - BrowserManager

/// Key başına BrowserModel önbelleği. WKWebView modelde yaşadığı için sekme
/// geçişleri sayfayı, çerezleri, scroll pozisyonunu ve izinleri korur.
@MainActor
final class BrowserManager: ObservableObject {
    private var models: [String: BrowserModel] = [:]

    /// `initialURL` yalnız model ilk yaratılırken kullanılır; sonraki çağrılar
    /// mevcut modeli navigasyon yapmadan döndürür (URL değişimi WebTabView'daki
    /// onChange ile ele alınır).
    func model(forKey key: String, initialURL: String) -> BrowserModel {
        if let existing = models[key] { return existing }
        let model = BrowserModel(initialURL: initialURL)
        models[key] = model
        return model
    }

    /// Tüm WKWebView'ları bırak (arka plan aktivitesi durur).
    func clearAll() {
        models.removeAll()
    }
}

// MARK: - BrowserModel

final class BrowserModel: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate {
    let webView: WKWebView
    @Published var addressBar: String
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    @Published var isMobile: Bool = false

    /// Sekme yapılandırmasından gelen son URL — aynı URL ile tekrar çağrı
    /// (no-op sekme geçişi) sayfayı yeniden yüklemesin diye takip edilir.
    private var lastConfigURL: String

    private var observations: [NSKeyValueObservation] = []

    private static let mobileUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    init(initialURL: String) {
        let config = WKWebViewConfiguration()
        // Kalıcı veri deposu: çerez, localStorage, IndexedDB uygulama yeniden
        // açılışlarında korunur.
        config.websiteDataStore = .default()
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Web Inspector: KVC anahtarı + macOS 13.3+ isInspectable — ikisi birden.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        if #available(macOS 13.3, *) {
            config.preferences.isElementFullscreenEnabled = true
        }

        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                 configuration: config)
        if #available(macOS 13.3, *) {
            self.webView.isInspectable = true
        }
        self.webView.customUserAgent = nil
        self.webView.allowsBackForwardNavigationGestures = true
        self.webView.allowsMagnification = true

        self.addressBar = initialURL
        self.lastConfigURL = initialURL
        super.init()

        self.webView.uiDelegate = self
        self.webView.navigationDelegate = self

        // KVO → main queue: @Published güncellemeleri her zaman main'de.
        observations.append(webView.observe(\.url, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async {
                if let url = view.url?.absoluteString { self?.addressBar = url }
            }
        })
        observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.canGoBack = view.canGoBack }
        })
        observations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.canGoForward = view.canGoForward }
        })
        observations.append(webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.isLoading = view.isLoading }
        })

        navigate(initialURL)
    }

    func navigate(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.contains("://") { s = "http://" + s }
        guard let url = URL(string: s) else { return }
        webView.load(URLRequest(url: url))
    }

    /// İkonun URL alanı değiştiğinde çağrılır — gerçekten farklıysa gider,
    /// böylece aynı sekmeye dönmek kullanıcının sayfa durumunu bozmaz.
    func navigateIfChanged(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s != lastConfigURL else { return }
        lastConfigURL = s
        navigate(s)
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }

    func reload() {
        if webView.isLoading {
            webView.stopLoading()
            return
        }
        // WKWebView.reload() ilk yükleme hiç bitmediyse no-op'tur (localhost dev
        // sunucusu kısa süre 502 verirse olur) — bu yüzden taze load(URLRequest).
        if let url = webView.url {
            webView.load(URLRequest(url: url))
        } else {
            navigate(addressBar)
        }
    }

    func setMobile(_ on: Bool) {
        isMobile = on
        webView.customUserAgent = on ? Self.mobileUA : nil
        // UA yalnız sonraki istekte uygulanır — değişikliği görmek için yenile.
        if let url = webView.url {
            webView.load(URLRequest(url: url))
        } else {
            navigate(addressBar)
        }
    }

    /// Geçerli URL'yi harici Chrome'da aç; Chrome yoksa varsayılan tarayıcı.
    func openInChrome() {
        let candidate = webView.url?.absoluteString ?? addressBar
        let resolved: URL? = candidate.contains("://")
            ? URL(string: candidate)
            : URL(string: "http://" + candidate)
        guard let url = resolved else { return }

        let chromePath = "/Applications/Google Chrome.app"
        if FileManager.default.fileExists(atPath: chromePath) {
            NSWorkspace.shared.open([url],
                                    withApplicationAt: URL(fileURLWithPath: chromePath),
                                    configuration: NSWorkspace.OpenConfiguration(),
                                    completionHandler: nil)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: WKUIDelegate

    /// getUserMedia() istemlerini otomatik onayla — varsayılan karar reddir.
    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    /// target=_blank / window.open bağlantılarını aynı webview'de yükle —
    /// varsayılan davranış (nil dönmek) bu linkleri sessizce yutar.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

// MARK: - WebTabView

/// Workspace web sekmesi. Model BrowserManager'da key başına yaşadığı için
/// sekme geçişleri WKWebView'i yeniden yaratmaz.
struct WebTabView: View {
    let key: String
    let url: String
    let manager: BrowserManager

    var body: some View {
        BrowserPane(url: url, model: manager.model(forKey: key, initialURL: url))
    }
}

private struct BrowserPane: View {
    let url: String
    @ObservedObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            webArea
        }
        // İkon düzenlenip URL değişirse mevcut WKWebView'i yıkmadan yeni sayfaya git.
        .onChange(of: url) { _, newURL in
            model.navigateIfChanged(newURL)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            navIcon(systemName: "chevron.left",
                    enabled: model.canGoBack,
                    help: "Geri") {
                model.goBack()
            }

            navIcon(systemName: "chevron.right",
                    enabled: model.canGoForward,
                    help: "İleri") {
                model.goForward()
            }

            navIcon(systemName: model.isLoading ? "xmark" : "arrow.clockwise",
                    enabled: true,
                    help: model.isLoading ? "Yüklemeyi durdur" : "Sayfayı yenile",
                    tint: model.isLoading ? .orange : .accentColor) {
                model.reload()
            }

            TextField("URL", text: $model.addressBar)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .onSubmit { model.navigate(model.addressBar) }

            navIcon(systemName: model.isMobile ? "iphone" : "laptopcomputer",
                    enabled: true,
                    help: model.isMobile ? "Masaüstü görünüme geç" : "Mobil görünüme geç",
                    tint: model.isMobile ? .accentColor : .secondary) {
                model.setMobile(!model.isMobile)
            }

            Button {
                model.openInChrome()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Chrome")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.accentColor.opacity(0.4), lineWidth: 0.5)
                )
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Geçerli URL'yi Google Chrome'da aç")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func navIcon(systemName: String,
                         enabled: Bool,
                         help: String,
                         tint: Color = .primary,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? tint : Color.secondary.opacity(0.4))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.secondary.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private var webArea: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if model.isMobile { Spacer(minLength: 0) }
                WebViewHost(webView: model.webView)
                    .frame(width: model.isMobile ? min(390, geo.size.width) : geo.size.width)
                if model.isMobile { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

/// Container deseni: WKWebView'i doğrudan makeNSView'dan döndürmek yerine bir
/// kapsayıcıya attach ederiz — sekme değişince updateNSView yeni webview'i
/// takas edebilsin diye (aksi halde eski sekmenin sayfası ekranda kalır).
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WebContainerView {
        let container = WebContainerView()
        container.autoresizingMask = [.width, .height]
        container.attach(webView)
        return container
    }

    func updateNSView(_ container: WebContainerView, context: Context) {
        container.attach(webView)
    }
}

final class WebContainerView: NSView {
    private weak var currentWebView: WKWebView?

    func attach(_ wv: WKWebView) {
        if currentWebView === wv { return }
        currentWebView?.removeFromSuperview()
        wv.removeFromSuperview()
        wv.frame = bounds
        wv.autoresizingMask = [.width, .height]
        addSubview(wv)
        currentWebView = wv
    }
}

import SwiftUI
import WebKit

/// In-app browser for pandora.com. Vision Safari gets Page-Not-Found on every
/// Pandora route because their site sniffs the platform; this web view
/// masquerades as a Windows desktop browser so Pandora serves the full site.
struct PandoraWebWindow: View {
    let url: URL
    @State private var model = WebViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button {
                    model.webView.goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!model.canGoBack)

                Button {
                    model.webView.goForward()
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .disabled(!model.canGoForward)

                Button {
                    model.webView.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }

                if model.isLoading {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Text(model.title.isEmpty ? "Pandora" : model.title)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            WebViewRepresentable(model: model, initialURL: url)
        }
    }
}

@MainActor
@Observable
final class WebViewModel: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var title = ""

    override init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.websiteDataStore = .default()   // persist the Pandora login
        webView = WKWebView(frame: .zero, configuration: config)
        // The whole point: don't look like a Vision Pro (or any Apple device
        // in "desktop mode") — look like a Windows PC running Chrome.
        webView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        super.init()
        webView.navigationDelegate = self
    }

    func sync() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        title = webView.title ?? ""
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.sync() }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in self.sync() }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in self.sync() }
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    let model: WebViewModel
    let initialURL: URL

    func makeUIView(context: Context) -> WKWebView {
        model.webView.load(URLRequest(url: initialURL))
        return model.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

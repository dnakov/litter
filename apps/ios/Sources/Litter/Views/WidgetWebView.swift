import SwiftUI
import WebKit

/// Container UIView that hosts a WKWebView but suppresses intrinsicContentSize
/// invalidations from propagating to SwiftUI's layout system.
class WidgetWebViewContainer: UIView {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        addSubview(webView)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        webView.frame = bounds
    }

    override var intrinsicContentSize: CGSize { .zero }
    override func invalidateIntrinsicContentSize() { /* suppress */ }
}

struct WidgetWebView: UIViewRepresentable {
    let widgetHTML: String
    let isFinalized: Bool
    var allowsScrollAndZoom: Bool = false
    var onMessage: ((Any) -> Void)?
    var heightBinding: Binding<CGFloat>?

    func makeCoordinator() -> Coordinator {
        Coordinator(onMessage: onMessage, heightBinding: heightBinding)
    }

    func makeUIView(context: Context) -> WidgetWebViewContainer {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "widget")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = allowsScrollAndZoom
        webView.scrollView.bounces = allowsScrollAndZoom
        if !allowsScrollAndZoom {
            webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        }
        webView.navigationDelegate = context.coordinator

        #if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif

        context.coordinator.webView = webView
        webView.loadHTMLString(Self.shellHTML, baseURL: nil)
        return WidgetWebViewContainer(webView: webView)
    }

    static func dismantleUIView(_ container: WidgetWebViewContainer, coordinator: Coordinator) {
        coordinator.teardown()
        container.webView.navigationDelegate = nil
        container.webView.configuration.userContentController.removeScriptMessageHandler(forName: "widget")
    }

    func updateUIView(_ container: WidgetWebViewContainer, context: Context) {
        let webView = container.webView
        guard !widgetHTML.isEmpty else { return }
        let coordinator = context.coordinator
        coordinator.onMessage = onMessage
        coordinator.heightBinding = heightBinding
        let escaped = Self.escapeJS(widgetHTML)
        guard escaped != coordinator.lastEscapedHTML || (isFinalized && !coordinator.hasFinalized) else { return }
        coordinator.lastEscapedHTML = escaped

        if isFinalized && !coordinator.hasFinalized {
            coordinator.hasFinalized = true
            coordinator.sendContent(escaped, runScripts: true)
        } else if !isFinalized {
            coordinator.scheduleUpdate(html: escaped)
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var webView: WKWebView?
        var onMessage: ((Any) -> Void)?
        var heightBinding: Binding<CGFloat>?
        var hasFinalized = false
        var lastEscapedHTML: String?
        private var shellReady = false
        private var queuedJS: String?
        private var updateTimer: Timer?
        private var pendingHTML: String?
        private var heightTimer: Timer?
        private var pendingHeight: CGFloat = 0
        private var lastCommittedHeight: CGFloat = 0

        init(onMessage: ((Any) -> Void)?, heightBinding: Binding<CGFloat>? = nil) {
            self.onMessage = onMessage
            self.heightBinding = heightBinding
        }

        func teardown() {
            updateTimer?.invalidate()
            updateTimer = nil
            heightTimer?.invalidate()
            heightTimer = nil
            webView = nil
        }

        func sendContent(_ escaped: String, runScripts: Bool) {
            let js = runScripts
                ? "window._setContent('\(escaped)'); window._runScripts();"
                : "window._setContent('\(escaped)');"
            if shellReady {
                webView?.evaluateJavaScript(js, completionHandler: nil)
            } else {
                queuedJS = js
            }
        }

        func scheduleUpdate(html: String) {
            pendingHTML = html
            guard updateTimer == nil else { return }
            updateTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                guard let self, let html = self.pendingHTML else { return }
                self.pendingHTML = nil
                self.updateTimer = nil
                self.sendContent(html, runScripts: false)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            shellReady = true
            if let js = queuedJS {
                queuedJS = nil
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "widget" else { return }
            if let dict = message.body as? [String: Any],
               dict["_type"] as? String == "height",
               let h = dict["value"] as? CGFloat, h > 0 {
                pendingHeight = h
                heightTimer?.invalidate()
                heightTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    let finalHeight = ceil(self.pendingHeight)
                    guard abs(finalHeight - self.lastCommittedHeight) > 1 else { return }
                    self.lastCommittedHeight = finalHeight
                    DispatchQueue.main.async {
                        self.heightBinding?.wrappedValue = finalHeight
                    }
                }
                return
            }
            onMessage?(message.body)
        }

        // Block navigation to external URLs
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .other || navigationAction.request.url?.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            // Allow CDN script loads
            if let host = navigationAction.request.url?.host {
                let allowedHosts = ["cdnjs.cloudflare.com", "esm.sh", "cdn.jsdelivr.net", "unpkg.com"]
                if allowedHosts.contains(host) {
                    decisionHandler(.allow)
                    return
                }
            }
            // Open external links in Safari
            if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }

    // MARK: - Shell HTML

    private static var _cachedHTML: String?
    private static var _cachedSlug: String?

    static var shellHTML: String {
        let theme = ThemeStore.shared.dark
        if let cached = _cachedHTML, _cachedSlug == theme.slug { return cached }
        let html = buildShellHTML(theme: theme)
        _cachedHTML = html
        _cachedSlug = theme.slug
        return html
    }

    private static func hexToRGBA(_ hex: String, _ alpha: Double) -> String {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count >= 6,
              let r = UInt8(h.prefix(2), radix: 16),
              let g = UInt8(h.dropFirst(2).prefix(2), radix: 16),
              let b = UInt8(h.dropFirst(4).prefix(2), radix: 16) else {
            return "rgba(128,128,128,\(alpha))"
        }
        return "rgba(\(r),\(g),\(b),\(alpha))"
    }

    private static func buildShellHTML(theme: ResolvedTheme) -> String {
        """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1.0">
    <style>
    :root {
        --color-background-primary: \(theme.background);
        --color-background-secondary: \(theme.surface);
        --color-background-tertiary: \(theme.surfaceLight);
        --color-background-info: #0d253a;
        --color-background-danger: #3a1414;
        --color-background-success: #0d2a14;
        --color-background-warning: #3a2a0d;
        --color-text-primary: \(theme.textPrimary);
        --color-text-secondary: \(theme.textSecondary);
        --color-text-tertiary: \(theme.textMuted);
        --color-text-info: \(theme.accent);
        --color-text-danger: \(theme.danger);
        --color-text-success: \(theme.success);
        --color-text-warning: \(theme.warning);
        --color-border-tertiary: \(hexToRGBA(theme.border, 0.15));
        --color-border-secondary: \(hexToRGBA(theme.border, 0.3));
        --color-border-primary: \(hexToRGBA(theme.border, 0.4));
        --color-border-info: \(hexToRGBA(theme.accent, 0.4));
        --color-border-danger: \(hexToRGBA(theme.danger, 0.4));
        --color-border-success: \(hexToRGBA(theme.success, 0.4));
        --color-border-warning: \(hexToRGBA(theme.warning, 0.4));
        --font-sans: -apple-system, system-ui, sans-serif;
        --font-serif: Georgia, 'Times New Roman', serif;
        --font-mono: 'SF Mono', SFMono-Regular, ui-monospace, monospace;
        --border-radius-md: 8px;
        --border-radius-lg: 12px;
        --border-radius-xl: 16px;
        color-scheme: dark;
    }
    * { box-sizing: border-box; }
    body {
        margin: 0;
        padding: 6px;
        font-family: var(--font-sans);
        background: transparent;
        color: var(--color-text-primary);
        font-size: 14px;
        line-height: 1.5;
        -webkit-text-size-adjust: none;
    }
    @keyframes _fadeIn {
        from { opacity: 0; transform: translateY(4px); }
        to { opacity: 1; transform: none; }
    }
    svg { max-width: 100%; height: auto; }
    .t { font-family: var(--font-sans); font-size: 14px; font-weight: 400; fill: var(--color-text-primary); }
    .ts { font-family: var(--font-sans); font-size: 12px; font-weight: 400; fill: var(--color-text-secondary); }
    .th { font-family: var(--font-sans); font-size: 14px; font-weight: 500; fill: var(--color-text-primary); }
    .box { fill: var(--color-background-secondary); stroke: var(--color-border-tertiary); stroke-width: 0.5; }
    .arr { stroke: var(--color-text-tertiary); stroke-width: 1.5; fill: none; }
    .leader { stroke: var(--color-border-tertiary); stroke-width: 0.5; stroke-dasharray: 4 3; fill: none; }
    .node { cursor: pointer; }
    .node:hover { opacity: 0.85; }
    .c-blue > rect, .c-blue > circle, .c-blue > ellipse { fill: #1e3a5f; stroke: rgba(96,165,250,0.4); }
    .c-blue > .t, .c-blue > .th { fill: #93c5fd; }
    .c-blue > .ts { fill: #60a5fa; }
    .c-teal > rect, .c-teal > circle, .c-teal > ellipse { fill: #134e4a; stroke: rgba(45,212,191,0.4); }
    .c-teal > .t, .c-teal > .th { fill: #5eead4; }
    .c-teal > .ts { fill: #2dd4bf; }
    .c-amber > rect, .c-amber > circle, .c-amber > ellipse { fill: #451a03; stroke: rgba(251,191,36,0.4); }
    .c-amber > .t, .c-amber > .th { fill: #fcd34d; }
    .c-amber > .ts { fill: #fbbf24; }
    .c-green > rect, .c-green > circle, .c-green > ellipse { fill: #14532d; stroke: rgba(74,222,128,0.4); }
    .c-green > .t, .c-green > .th { fill: #86efac; }
    .c-green > .ts { fill: #4ade80; }
    .c-red > rect, .c-red > circle, .c-red > ellipse { fill: #450a0a; stroke: rgba(248,113,113,0.4); }
    .c-red > .t, .c-red > .th { fill: #fca5a5; }
    .c-red > .ts { fill: #f87171; }
    .c-purple > rect, .c-purple > circle, .c-purple > ellipse { fill: #2e1065; stroke: rgba(168,85,247,0.4); }
    .c-purple > .t, .c-purple > .th { fill: #c4b5fd; }
    .c-purple > .ts { fill: #a78bfa; }
    .c-coral > rect, .c-coral > circle, .c-coral > ellipse { fill: #431407; stroke: rgba(251,146,60,0.4); }
    .c-coral > .t, .c-coral > .th { fill: #fdba74; }
    .c-coral > .ts { fill: #fb923c; }
    .c-pink > rect, .c-pink > circle, .c-pink > ellipse { fill: #500724; stroke: rgba(244,114,182,0.4); }
    .c-pink > .t, .c-pink > .th { fill: #f9a8d4; }
    .c-pink > .ts { fill: #f472b6; }
    .c-gray > rect, .c-gray > circle, .c-gray > ellipse { fill: var(--color-background-tertiary); stroke: var(--color-border-secondary); }
    .c-gray > .t, .c-gray > .th { fill: var(--color-text-primary); }
    .c-gray > .ts { fill: var(--color-text-secondary); }
    </style>
    </head><body><div id="root"></div>
    <script>
    window._morphReady = false;
    window._pending = null;
    window._lastHeight = 0;
    window._heightObserver = null;
    window._reportHeight = function() {
        var r = document.getElementById('root');
        if (!r) return;
        var next = Math.ceil(Math.max(r.offsetHeight, r.scrollHeight)) + 12;
        if (!next || Math.abs(next - window._lastHeight) < 1) return;
        window._lastHeight = next;
        window.webkit.messageHandlers.widget.postMessage({_type:'height', value: next});
    };
    window._attachHeightObserver = function() {
        var r = document.getElementById('root');
        if (!r || window._heightObserver) return;
        window._heightObserver = new ResizeObserver(function() {
            window._reportHeight();
        });
        window._heightObserver.observe(r);
    };
    window._setContent = function(html) {
        if (!window._morphReady) { window._pending = html; return; }
        var root = document.getElementById('root');
        var target = document.createElement('div');
        target.id = 'root';
        target.innerHTML = html;
        morphdom(root, target, {
            onBeforeElUpdated: function(from, to) {
                if (from.isEqualNode(to)) return false;
                return true;
            },
            onNodeAdded: function(node) {
                if (node.nodeType === 1 && node.tagName !== 'STYLE' && node.tagName !== 'SCRIPT') {
                    node.style.animation = '_fadeIn 0.3s ease both';
                }
                return node;
            }
        });
        window._attachHeightObserver();
        setTimeout(function() {
            window._reportHeight();
        }, 60);
    };
    window._runScripts = function() {
        document.querySelectorAll('#root script').forEach(function(old) {
            var s = document.createElement('script');
            if (old.src) { s.src = old.src; } else { s.textContent = old.textContent; }
            old.parentNode.replaceChild(s, old);
        });
        window._attachHeightObserver();
        setTimeout(function() {
            window._reportHeight();
        }, 250);
    };
    window.sendPrompt = function(text) {
        window.webkit.messageHandlers.widget.postMessage({_type:'sendPrompt', text: text});
    };
    window.openLink = function(url) {
        window.webkit.messageHandlers.widget.postMessage({_type:'openLink', url: url});
    };
    </script>
    <script src="https://cdn.jsdelivr.net/npm/morphdom@2.7.4/dist/morphdom-umd.min.js"
        onload="window._morphReady=true;if(window._pending){window._setContent(window._pending);window._pending=null;}"></script>
    </body></html>
    """
    }

    // MARK: - JS Escape

    static func escapeJS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "</script>", with: "<\\/script>")
    }
}

// MARK: - Height notification

extension Notification.Name {
    static let widgetHeightChanged = Notification.Name("widgetHeightChanged")
}

// MARK: - Container View

struct WidgetContainerView: View {
    let widget: WidgetState
    var onMessage: ((Any) -> Void)?
    private let minimumInlineHeight: CGFloat = 200

    @State private var contentHeight: CGFloat
    @State private var isFullscreen = false

    init(widget: WidgetState, onMessage: ((Any) -> Void)? = nil) {
        self.widget = widget
        self.onMessage = onMessage
        _contentHeight = State(initialValue: max(widget.height, 200))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            widgetView
                .frame(height: max(contentHeight, minimumInlineHeight))
            HStack(spacing: 8) {
                if !widget.isFinalized {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(LitterTheme.accentStrong)
                }
                Spacer()
                Button {
                    isFullscreen = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .medium))
                        Text("Expand")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(LitterTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(LitterTheme.surfaceLight.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.top, 6)
        }
        .fullScreenCover(isPresented: $isFullscreen) {
            fullscreenWidget
        }
    }

    private var widgetView: some View {
        WidgetWebView(
            widgetHTML: widget.widgetHTML,
            isFinalized: widget.isFinalized,
            onMessage: onMessage,
            heightBinding: $contentHeight
        )
    }

    private var fullscreenWidget: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            WidgetWebView(
                widgetHTML: widget.widgetHTML,
                isFinalized: true,
                allowsScrollAndZoom: true,
                onMessage: onMessage
            )
            .ignoresSafeArea()

            Button {
                isFullscreen = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(16)
            }
        }
    }
}

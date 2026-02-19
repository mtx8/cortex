import SwiftUI
import WebKit

/// NSViewRepresentable wrapper that loads TradingView's Advanced Chart widget
/// inside a WKWebView. The widget is configured for dark theme, the requested
/// symbol / timeframe, and includes RSI, MACD, and Volume studies.
public struct TradingViewWebView: NSViewRepresentable {
    let symbol: String
    let timeframe: String

    public init(symbol: String, timeframe: String) {
        self.symbol = symbol
        self.timeframe = timeframe
    }

    // MARK: - NSViewRepresentable

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "javaScriptEnabled")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        loadChart(webView: webView)
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        loadChart(webView: webView)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Chart Loading

    private func loadChart(webView: WKWebView) {
        let interval = Self.mapTimeframe(timeframe)
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>
                * { margin: 0; padding: 0; }
                body { background: #1e1e2e; overflow: hidden; }
                #tradingview_widget { width: 100%; height: 100vh; }
            </style>
        </head>
        <body>
            <div class="tradingview-widget-container">
                <div id="tradingview_widget"></div>
            </div>
            <script type="text/javascript" src="https://s3.tradingview.com/tv.js"></script>
            <script type="text/javascript">
                new TradingView.widget({
                    "autosize": true,
                    "symbol": "\(symbol)",
                    "interval": "\(interval)",
                    "timezone": "America/New_York",
                    "theme": "dark",
                    "style": "1",
                    "locale": "en",
                    "toolbar_bg": "#1e1e2e",
                    "enable_publishing": false,
                    "hide_top_toolbar": false,
                    "hide_legend": false,
                    "save_image": false,
                    "container_id": "tradingview_widget",
                    "studies": [
                        "RSI@tv-basicstudies",
                        "MACD@tv-basicstudies",
                        "Volume@tv-basicstudies"
                    ]
                });
            </script>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.tradingview.com"))
    }

    // MARK: - Timeframe Mapping

    /// Maps display timeframes to TradingView interval values.
    static func mapTimeframe(_ tf: String) -> String {
        switch tf {
        case "1m": return "1"
        case "5m": return "5"
        case "15m": return "15"
        case "1H": return "60"
        case "4H": return "240"
        case "D": return "D"
        case "W": return "W"
        default: return "D"
        }
    }

    // MARK: - Coordinator

    public class Coordinator: NSObject, WKNavigationDelegate {
        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(.allow)
        }
    }
}

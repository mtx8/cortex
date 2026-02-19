import SwiftUI
import WebKit

/// Chart View — embeds a TradingView advanced chart widget via WKWebView.
/// Provides a timeframe selector toolbar and renders candlestick data
/// with RSI, MACD, and Volume studies.
@MainActor
public struct ChartView: View {
    let symbol: String
    @State private var timeframe: String = "D"

    public init(symbol: String = "AAPL") {
        self.symbol = symbol
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar with symbol name and timeframe selector
            HStack {
                Text(symbol)
                    .font(.system(.title2, design: .monospaced, weight: .bold))

                Spacer()

                ForEach(["1m", "5m", "15m", "1H", "4H", "D", "W"], id: \.self) { tf in
                    Button(tf) { timeframe = tf }
                        .buttonStyle(.bordered)
                        .tint(timeframe == tf ? .blue : .gray)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // TradingView chart
            TradingViewWebView(symbol: symbol, timeframe: timeframe)
        }
    }
}

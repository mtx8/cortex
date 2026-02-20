import SwiftUI

/// Order entry panel with quantity, order type, buy/sell buttons, and trading mode.
public struct OrderPanelView: View {
    let store: TradeStore
    @State private var symbol: String = ""
    @State private var quantity: String = "100"
    @State private var orderType: String = "MARKET"
    @State private var limitPrice: String = ""

    private let orderTypes = ["MARKET", "LIMIT", "STOP"]

    public init(store: TradeStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(CortexDesign.border)
            ScrollView {
                VStack(spacing: 12) {
                    tradingModeSelector
                    symbolField
                    quantityField
                    orderTypeSelector
                    if orderType != "MARKET" {
                        priceField
                    }
                    actionButtons
                    pendingOrdersList
                }
                .padding(12)
            }
        }
        .background(CortexDesign.bgDeepest)
        .onAppear {
            symbol = store.activeSymbol
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 10))
                .foregroundStyle(CortexDesign.accentPrimary)

            Text("ORDER ENTRY")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            // Trading mode badge
            Text(store.tradingMode.rawValue.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(tradingModeColor.opacity(0.15))
                )
                .foregroundStyle(tradingModeColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(CortexDesign.bgCard)
    }

    // MARK: - Trading Mode

    private var tradingModeSelector: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TRADING MODE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                ForEach(TradeStore.TradingMode.allCases, id: \.self) { mode in
                    Button(action: { store.setTradingMode(mode) }) {
                        Text(mode.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(store.tradingMode == mode
                                          ? modeColor(mode).opacity(0.2)
                                          : Color(white: 0.10))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        store.tradingMode == mode
                                            ? modeColor(mode).opacity(0.5)
                                            : Color(white: 0.15),
                                        lineWidth: 1
                                    )
                            )
                            .foregroundStyle(store.tradingMode == mode ? modeColor(mode) : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Fields

    private var symbolField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SYMBOL")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            TextField("AAPL", text: $symbol)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(CortexDesign.bgElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(CortexDesign.border, lineWidth: 1)
                )
                .onSubmit {
                    store.activeSymbol = symbol.uppercased()
                }
        }
    }

    private var quantityField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("QUANTITY")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                TextField("100", text: $quantity)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CortexDesign.bgElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(CortexDesign.border, lineWidth: 1)
                    )

                // Quick quantity buttons
                ForEach(["10", "50", "100", "500"], id: \.self) { qty in
                    Button(action: { quantity = qty }) {
                        Text(qty)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(quantity == qty ? CortexDesign.accentPrimary.opacity(0.15) : Color(white: 0.10))
                            )
                            .foregroundStyle(quantity == qty ? CortexDesign.accentPrimary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var orderTypeSelector: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ORDER TYPE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                ForEach(orderTypes, id: \.self) { type in
                    Button(action: { orderType = type }) {
                        Text(type)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(orderType == type
                                          ? CortexDesign.accentSecondary.opacity(0.15)
                                          : Color(white: 0.10))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        orderType == type
                                            ? CortexDesign.accentSecondary.opacity(0.5)
                                            : Color(white: 0.15),
                                        lineWidth: 1
                                    )
                            )
                            .foregroundStyle(orderType == type ? CortexDesign.accentSecondary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var priceField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(orderType == "LIMIT" ? "LIMIT PRICE" : "STOP PRICE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            TextField("0.00", text: $limitPrice)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(CortexDesign.bgElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(CortexDesign.border, lineWidth: 1)
                )
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button(action: { submitOrder(side: "BUY") }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 12))
                    Text("BUY")
                        .font(.system(size: 13, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(CortexDesign.profit.opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(CortexDesign.profit.opacity(0.4), lineWidth: 1)
                )
                .foregroundStyle(CortexDesign.profit)
            }
            .buttonStyle(.plain)

            Button(action: { submitOrder(side: "SELL") }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12))
                    Text("SELL")
                        .font(.system(size: 13, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(CortexDesign.loss.opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(CortexDesign.loss.opacity(0.4), lineWidth: 1)
                )
                .foregroundStyle(CortexDesign.loss)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Pending Orders

    @ViewBuilder
    private var pendingOrdersList: some View {
        if !store.pendingOrders.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("PENDING ORDERS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                ForEach(store.pendingOrders) { order in
                    HStack(spacing: 8) {
                        Text(order.side)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(order.side == "BUY" ? CortexDesign.profit : CortexDesign.loss)

                        Text(order.symbol)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)

                        Text("x\(order.quantity)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Text(order.orderType)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)

                        if let price = order.limitPrice {
                            Text(String(format: "$%.2f", price))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(action: { store.cancelOrder(orderId: order.id) }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(CortexDesign.loss.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CortexDesign.bgCard)
                    )
                }
            }
        }
    }

    // MARK: - Actions

    private func submitOrder(side: String) {
        let sym = symbol.uppercased()
        guard !sym.isEmpty, let qty = Int(quantity), qty > 0 else { return }
        let price: Double? = orderType != "MARKET" ? Double(limitPrice) : nil
        store.submitOrder(symbol: sym, side: side, quantity: qty, type: orderType, price: price)
    }

    // MARK: - Helpers

    private var tradingModeColor: Color {
        modeColor(store.tradingMode)
    }

    private func modeColor(_ mode: TradeStore.TradingMode) -> Color {
        switch mode {
        case .manual: return .blue
        case .semiAuto: return .orange
        case .fullAuto: return .green
        }
    }
}

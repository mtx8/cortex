import SwiftUI

public struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Environment(\.cortexSelectedSection) private var selectedSection

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public var body: some View {
        switch selectedSection {
        case "Connection":
            connectionSection
        case "API Keys":
            apiKeysSection
        case "Risk Limits":
            riskLimitsSection
        case "Autonomy":
            autonomySection
        case "Appearance":
            appearancePlaceholder
        default:
            allSettingsForm
        }
    }

    // MARK: - All Settings (default)

    @ViewBuilder
    private var allSettingsForm: some View {
        Form {
            Section("Connection") {
                connectionFields
            }

            Section("Autonomy") {
                autonomyFields
            }

            Section("Risk Limits") {
                riskLimitsFields
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
    }

    // MARK: - Connection Section

    @ViewBuilder
    private var connectionSection: some View {
        Form {
            Section("Connection") {
                connectionFields
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 200)
    }

    @ViewBuilder
    private var connectionFields: some View {
        TextField("Server URL", text: $settings.serverURL)
            .textFieldStyle(.roundedBorder)
        HStack {
            Circle()
                .fill(settings.isConnected ? CortexDesign.profit : CortexDesign.loss)
                .frame(width: 8, height: 8)
            Text(settings.isConnected ? "Connected" : "Disconnected")
                .foregroundColor(.secondary)
        }
    }

    // MARK: - API Keys Section

    @ViewBuilder
    private var apiKeysSection: some View {
        Form {
            Section("API Keys") {
                Text("API keys are managed in ~/.cortex/secrets.toml")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Anthropic (Claude)") {
                HStack {
                    Text("API Key")
                    Spacer()
                    Text("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section("Interactive Brokers") {
                HStack {
                    Text("Gateway Host")
                    Spacer()
                    Text("127.0.0.1")
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Text("Gateway Port")
                    Spacer()
                    Text("4002")
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section("Polygon.io") {
                HStack {
                    Text("API Key")
                    Spacer()
                    Text("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section("Unusual Whales") {
                HStack {
                    Text("API Key")
                    Spacer()
                    Text("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
    }

    // MARK: - Risk Limits Section

    @ViewBuilder
    private var riskLimitsSection: some View {
        Form {
            Section("Risk Limits") {
                riskLimitsFields
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 200)
    }

    @ViewBuilder
    private var riskLimitsFields: some View {
        HStack {
            Text("Max Notional per Trade")
            Spacer()
            Text("$\(settings.maxNotional, specifier: "%.0f")")
                .foregroundColor(.secondary)
        }
        HStack {
            Text("Max Daily Loss")
            Spacer()
            TextField("$", value: $settings.maxDailyLoss, format: .currency(code: "USD"))
                .frame(width: 100)
                .textFieldStyle(.roundedBorder)
        }
        HStack {
            Text("Max Drawdown")
            Spacer()
            Text("\(settings.maxDrawdownPct, specifier: "%.1f")%")
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Autonomy Section

    @ViewBuilder
    private var autonomySection: some View {
        Form {
            Section("Autonomy") {
                autonomyFields
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 200)
    }

    @ViewBuilder
    private var autonomyFields: some View {
        Picker("Level", selection: $settings.autonomyLevel) {
            ForEach(AutonomyLevel.allCases) { level in
                Text(level.label).tag(level)
            }
        }
        Text(settings.autonomyLevel.description)
            .font(.caption)
            .foregroundColor(.secondary)
        if settings.autonomyLevel == .semiAuto {
            HStack {
                Text("Auto-approve below")
                Spacer()
                TextField("$", value: $settings.autoThreshold, format: .currency(code: "USD"))
                    .frame(width: 100)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Appearance Placeholder

    @ViewBuilder
    private var appearancePlaceholder: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "paintbrush")
                .font(.system(size: 40))
                .foregroundStyle(CortexDesign.border)

            Text("Appearance")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(CortexDesign.neutral)

            Text("Theme and appearance settings coming soon.\nCustomize colors, density, and chart preferences.")
                .font(.system(size: 12))
                .foregroundStyle(CortexDesign.neutral)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CortexDesign.bgDeepest)
    }
}

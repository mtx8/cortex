import SwiftUI

public struct SettingsView: View {
    @Bindable var settings: SettingsStore

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public var body: some View {
        Form {
            Section("Connection") {
                TextField("Server URL", text: $settings.serverURL)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Circle()
                        .fill(settings.isConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(settings.isConnected ? "Connected" : "Disconnected")
                        .foregroundColor(.secondary)
                }
            }

            Section("Autonomy") {
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

            Section("Risk Limits") {
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
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
    }
}

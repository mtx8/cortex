import SwiftUI

/// War Room -- the main command dashboard for CORTEX.
/// Shows KPI bar, squadron grid, scanner preview, opportunity feed, and activity log.
@MainActor
public struct WarRoomView: View {
    let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        VStack(spacing: 0) {
            // KPI Bar across the top
            KPIBar(portfolio: environment.portfolio)

            Divider()
                .overlay(Color(white: 0.15))

            // Kill switch header
            KillSwitchHeader(killSwitch: environment.killSwitch)

            Divider()
                .overlay(Color(white: 0.15))

            // Main content split
            HSplitView {
                // Left column: Squadron Status Grid + Scanner Preview
                VStack(spacing: 0) {
                    SquadronStatusGrid(squadrons: environment.squadrons)

                    Divider()
                        .overlay(Color(white: 0.15))

                    ScannerPreview(opportunities: environment.opportunities)

                    Spacer(minLength: 0)
                }
                .frame(minWidth: 450)

                // Right column: Opportunities Feed + Activity Feed
                VStack(spacing: 0) {
                    OpportunityFeedView(opportunities: environment.opportunities)

                    Divider()
                        .overlay(Color(white: 0.15))

                    WarRoomActivityFeedView(activity: environment.activity)
                }
                .frame(minWidth: 350)
            }
        }
        .background(Color(nsColor: NSColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 1.0)))
    }
}

// MARK: - Kill Switch Header

@MainActor
struct KillSwitchHeader: View {
    let killSwitch: KillSwitchStore

    var body: some View {
        HStack {
            Image(systemName: "shield.checkmark.fill")
                .font(.system(size: 14))
                .foregroundStyle(killSwitch.isActive ? .red : .green)

            Text(killSwitch.isActive ? "KILL SWITCH ENGAGED" : "ALL SYSTEMS NOMINAL")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(killSwitch.isActive ? .red : .green)

            Spacer()

            KillSwitchButton(store: killSwitch)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(
            (killSwitch.isActive ? Color.red : Color.green).opacity(0.05)
        )
    }
}

// MARK: - Kill Switch Button

struct KillSwitchButton: View {
    let store: KillSwitchStore

    var body: some View {
        Button(action: {
            if store.isActive {
                store.disengage()
            } else {
                store.engage()
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: store.isActive ? "exclamationmark.octagon.fill" : "shield.checkmark")
                Text(store.isActive ? "DISARM" : "ARMED")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(store.isActive ? Color.red : Color.green.opacity(0.2))
            .foregroundStyle(store.isActive ? .white : .green)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Activity Feed (War Room version)

@MainActor
struct WarRoomActivityFeedView: View {
    let activity: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ACTIVITY")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(activity.events.count) events")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(activity.recentEvents.prefix(30)) { event in
                        HStack(spacing: 8) {
                            Image(systemName: severityIcon(event.severity))
                                .font(.system(size: 10))
                                .foregroundStyle(severityColor(event.severity))
                                .frame(width: 14)

                            Text(event.message)
                                .font(.system(size: 11))
                                .foregroundStyle(Color(white: 0.7))
                                .lineLimit(1)

                            Spacer()

                            Text(event.timestamp, style: .time)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    func severityIcon(_ severity: ActivityEvent.Severity) -> String {
        switch severity {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    func severityColor(_ severity: ActivityEvent.Severity) -> Color {
        switch severity {
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

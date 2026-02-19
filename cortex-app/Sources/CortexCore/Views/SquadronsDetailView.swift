import SwiftUI

/// Squadrons detail view placeholder — will show detailed agent management.
public struct SquadronsDetailView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Squadrons")
                .font(.system(.title, design: .monospaced, weight: .bold))
            Text("Detailed view of all 6 squadrons and their agents.\nAlpha through Foxtrot with real-time status monitoring.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

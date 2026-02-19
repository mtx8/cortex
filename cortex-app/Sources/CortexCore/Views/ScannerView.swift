import SwiftUI

/// Scanner view placeholder — will be wired to the Rust scanner engine.
public struct ScannerView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Scanner")
                .font(.system(.title, design: .monospaced, weight: .bold))
            Text("Real-time market scanner powered by the Rust engine.\nWill display scanner results when the backend is connected.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import SwiftUI

/// A Bloomberg-style command line: type a mnemonic (DES, GP, OMON, ECO, PORT, GEO…)
/// or a tab name and jump there. Opened with ⌘⇧P (⌘K is reserved for the kill switch).
public struct CommandItem: Identifiable, Sendable {
    public let id: String
    public let mnemonic: String
    public let title: String
    public let tab: AppTab
    public init(_ mnemonic: String, _ title: String, _ tab: AppTab) {
        self.id = mnemonic
        self.mnemonic = mnemonic
        self.title = title
        self.tab = tab
    }
}

public enum CommandCatalog {
    public static let items: [CommandItem] = [
        .init("WAR", "War Room", .warRoom),
        .init("GP", "Markets / Charts", .markets),
        .init("EQS", "Scanner", .scanner),
        .init("SCAN", "Scanner", .scanner),
        .init("OMON", "Trade & Options", .trade),
        .init("DES", "Financials / Description", .financials),
        .init("FA", "Fundamentals", .financials),
        .init("WL", "Watchlist", .watchlist),
        .init("SQ", "Squadrons", .squadrons),
        .init("PORT", "Performance / Portfolio", .performance),
        .init("GEO", "Geo-Intelligence", .geoIntelligence),
        .init("ECO", "Macro / Rates (Geo-Intel)", .geoIntelligence),
        .init("SET", "Settings", .settings),
    ]

    public static func filter(_ q: String) -> [CommandItem] {
        let t = q.trimmingCharacters(in: .whitespaces).uppercased()
        if t.isEmpty { return items }
        return items.filter {
            $0.mnemonic.contains(t) || $0.title.uppercased().contains(t)
                || $0.tab.rawValue.uppercased().contains(t)
        }
    }
}

public struct CommandPalette: View {
    @Binding var isPresented: Bool
    let onSelect: (AppTab) -> Void
    @State private var query: String = ""
    @FocusState private var focused: Bool

    public init(isPresented: Binding<Bool>, onSelect: @escaping (AppTab) -> Void) {
        self._isPresented = isPresented
        self.onSelect = onSelect
    }

    private var results: [CommandItem] { CommandCatalog.filter(query) }

    public var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "command").foregroundStyle(CortexDesign.accentPrimary)
                    TextField("DES · GP · OMON · ECO · PORT · GEO …", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, design: .monospaced))
                        .focused($focused)
                        .onSubmit { if let f = results.first { choose(f) } }
                }
                .padding(12)
                Divider().overlay(CortexDesign.border)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(results) { item in
                            Button { choose(item) } label: {
                                HStack(spacing: 10) {
                                    Text(item.mnemonic)
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundStyle(CortexDesign.accentPrimary)
                                        .frame(width: 56, alignment: .leading)
                                    Text(item.title).foregroundStyle(Color(white: 0.9))
                                    Spacer()
                                    Image(systemName: item.tab.icon).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if results.isEmpty {
                            Text("No match").font(CortexDesign.labelFont)
                                .foregroundStyle(.secondary).padding(16)
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
            .frame(width: 540)
            .background(RoundedRectangle(cornerRadius: 12).fill(CortexDesign.bgElevated))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(CortexDesign.borderHover, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
            .padding(.top, 110)
        }
        .onAppear { focused = true }
        .onExitCommand { isPresented = false }   // Esc dismisses
    }

    private func choose(_ item: CommandItem) {
        onSelect(item.tab)
        isPresented = false
    }
}

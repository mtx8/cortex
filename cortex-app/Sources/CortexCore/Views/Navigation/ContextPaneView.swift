import SwiftUI

/// Left context pane showing sections for the currently selected tab.
/// 220px wide, collapsible to 0px.
public struct ContextPaneView: View {
    let tab: AppTab
    @Binding var selectedSection: String

    @State private var hoveredSection: String? = nil

    public init(tab: AppTab, selectedSection: Binding<String>) {
        self.tab = tab
        self._selectedSection = selectedSection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pane header: current tab name
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.cyan)
                Text(tab.rawValue.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.5))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
                .overlay(Color(white: 0.12))

            // Section links
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(tab.sections, id: \.label) { section in
                        ContextSectionButton(
                            icon: section.icon,
                            label: section.label,
                            isSelected: selectedSection == section.label,
                            isHovered: hoveredSection == section.label
                        ) {
                            selectedSection = section.label
                        }
                        .onHover { hovering in
                            hoveredSection = hovering ? section.label : nil
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }

            Spacer()
        }
        .frame(width: 220)
        .background(Color(nsColor: NSColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 1.0)))
    }
}

// MARK: - Context Section Button

struct ContextSectionButton: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .cyan : Color(white: 0.5))
                    .frame(width: 20, height: 20)

                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : Color(white: 0.6))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isSelected
                            ? Color.cyan.opacity(0.12)
                            : isHovered ? Color(white: 0.10) : Color.clear
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isSelected ? Color.cyan.opacity(0.25) : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI

/// Left context pane showing sections for the currently selected tab.
/// Three modes: `.full` (220px), `.iconOnly` (52px), `.hidden` (0px).
public struct ContextPaneView: View {
    let tab: AppTab
    @Binding var selectedSection: String
    @Binding var mode: ContextPaneMode

    @State private var hoveredSection: String? = nil

    public init(tab: AppTab, selectedSection: Binding<String>, mode: Binding<ContextPaneMode>) {
        self.tab = tab
        self._selectedSection = selectedSection
        self._mode = mode
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pane header
            paneHeader

            Divider()
                .overlay(Color(white: 0.12))

            // Section links
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(tab.sections, id: \.label) { section in
                        sectionButton(for: section)
                    }
                }
                .padding(.horizontal, mode == .full ? 8 : 4)
                .padding(.vertical, 8)
            }

            Spacer()
        }
        .frame(width: mode.width)
        .background(Color(nsColor: NSColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 1.0)))
        .clipped()
    }

    // MARK: - Pane Header

    @ViewBuilder
    private var paneHeader: some View {
        if mode == .full {
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
        } else {
            // Icon-only header: just the tab icon centered
            Image(systemName: tab.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.cyan)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .help(tab.rawValue)
        }
    }

    // MARK: - Section Button

    @ViewBuilder
    private func sectionButton(for section: (icon: String, label: String)) -> some View {
        let isSelected = selectedSection == section.label
        let isHovered = hoveredSection == section.label

        if mode == .full {
            // Full mode: icon + label with cyan left border
            ContextSectionButtonFull(
                icon: section.icon,
                label: section.label,
                isSelected: isSelected,
                isHovered: isHovered
            ) {
                selectedSection = section.label
            }
            .onHover { hovering in
                hoveredSection = hovering ? section.label : nil
            }
        } else {
            // Icon-only mode: centered icon with tooltip
            ContextSectionButtonIcon(
                icon: section.icon,
                label: section.label,
                isSelected: isSelected,
                isHovered: isHovered
            ) {
                selectedSection = section.label
            }
            .onHover { hovering in
                hoveredSection = hovering ? section.label : nil
            }
        }
    }

}

// MARK: - Full Mode Section Button (icon + label + cyan left border)

struct ContextSectionButtonFull: View {
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
                    .foregroundStyle(isSelected ? Color(white: 0.85) : Color(white: 0.6))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isSelected
                            ? Color.cyan.opacity(0.10)
                            : isHovered ? Color(white: 0.08) : Color.clear
                    )
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.cyan)
                        .frame(width: 3)
                        .padding(.vertical, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Icon-Only Mode Section Button (centered icon + tooltip)

struct ContextSectionButtonIcon: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .cyan : Color(white: 0.5))
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            isSelected
                                ? Color.cyan.opacity(0.10)
                                : isHovered ? Color(white: 0.08) : Color.clear
                        )
                )
                .overlay(alignment: .leading) {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.cyan)
                            .frame(width: 3, height: 24)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

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
                .overlay(CortexDesign.border)

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
        .background(CortexDesign.bgDeepest)
        .clipped()
    }

    // MARK: - Pane Header

    @ViewBuilder
    private var paneHeader: some View {
        if mode == .full {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CortexDesign.accentPrimary)
                Text(tab.rawValue.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(CortexDesign.neutral)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        } else {
            // Icon-only header: just the tab icon centered
            Image(systemName: tab.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CortexDesign.accentPrimary)
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
                    .foregroundStyle(isSelected ? .cyan : CortexDesign.neutral)
                    .frame(width: 20, height: 20)

                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : CortexDesign.neutral)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isSelected
                            ? CortexDesign.accentPrimary.opacity(0.10)
                            : isHovered ? CortexDesign.bgCard : Color.clear
                    )
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(CortexDesign.accentPrimary)
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
                .foregroundStyle(isSelected ? .cyan : CortexDesign.neutral)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            isSelected
                                ? CortexDesign.accentPrimary.opacity(0.10)
                                : isHovered ? CortexDesign.bgCard : Color.clear
                        )
                )
                .overlay(alignment: .leading) {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(CortexDesign.accentPrimary)
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

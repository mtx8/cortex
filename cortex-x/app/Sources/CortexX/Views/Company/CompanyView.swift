// COMPANY — Bloomberg-SPLC-class company intelligence board.
// suppliers | the company (segments + fundamentals) | customers.
// Placeholder pending the company-view build task; keeps the shell compiling.

import SwiftUI

struct CompanyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            SectionLabel(text: "company")
            Text("company intelligence loading…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
        .task(id: model.selectedSymbol) {
            model.requestCompany(model.selectedSymbol)
        }
    }
}

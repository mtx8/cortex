// Shell state tests: center-section order (must match the icon rail) and
// the COMPANY navigation entry point.

import XCTest
@testable import CortexX

@MainActor
final class ShellTests: XCTestCase {
    func testCenterModeHasSevenCasesInRailOrder() {
        XCTAssertEqual(
            AppModel.CenterMode.allCases,
            [.chart, .scanner, .company, .options, .foundry, .regimes, .meridian]
        )
    }

    func testOpenCompanySwitchesModeAndMarksLoading() {
        let model = AppModel()
        XCTAssertEqual(model.centerMode, .chart)

        model.openCompany("NVDA")

        XCTAssertEqual(model.centerMode, .company)
        XCTAssertTrue(model.companyLoading)
    }
}

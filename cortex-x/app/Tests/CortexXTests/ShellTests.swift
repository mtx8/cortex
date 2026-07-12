// Shell state tests: center-section order (must match the icon rail) and
// the COMPANY navigation entry point.

import XCTest
@testable import CortexX

@MainActor
final class ShellTests: XCTestCase {
    func testCenterModeHasSixCasesInRailOrder() {
        XCTAssertEqual(
            AppModel.CenterMode.allCases,
            [.chart, .company, .options, .foundry, .regimes, .meridian]
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

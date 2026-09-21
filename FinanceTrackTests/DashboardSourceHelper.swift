import XCTest
@testable import FinanceTrack

extension FinanceTrackTests {
    /// The text of `DashboardView.swift`, for the source-scan tests that check how it is wired.
    static func dashboardViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("FinanceTrack/Views/Dashboard/DashboardView.swift"), encoding: .utf8)
    }
}

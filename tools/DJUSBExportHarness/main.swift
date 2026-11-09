import XCTest

let suite = XCTestSuite(forTestCaseClass: DJUSBExportRoundTripTests.self)
suite.run()
let run = suite.testRun!
print("\(run.executionCount) tests, \(run.totalFailureCount) failures")
exit(run.hasSucceeded ? 0 : 1)

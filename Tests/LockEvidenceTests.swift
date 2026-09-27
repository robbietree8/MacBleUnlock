import XCTest
@testable import MacBleUnlock

/// 这是决定「要不要把登录密码注入」的唯一闸门，因此把判定规则钉死：
/// 至少两票同意才算在锁屏；只有一票时一律判为不在锁屏（宁可不解锁）。
final class LockEvidenceTests: XCTestCase {

    func testNoSignalsMeansNotLocked() {
        let verdict = LockEvidence.evaluate(stateLocked: false, sessionLocked: false, frontmostBundleID: "com.apple.Terminal")
        XCTAssertFalse(verdict.locked)
        XCTAssertEqual(verdict.votes, 0)
    }

    func testSingleSignalIsNotEnough() {
        // 只有通知状态说是锁屏 —— 可能是漏收了 screenIsUnlocked，不足以注入密码。
        XCTAssertFalse(LockEvidence.evaluate(stateLocked: true, sessionLocked: false, frontmostBundleID: "com.apple.Terminal").locked)

        // 只有 CGSession 说是锁屏。
        XCTAssertFalse(LockEvidence.evaluate(stateLocked: false, sessionLocked: true, frontmostBundleID: "com.apple.Terminal").locked)

        // 只有前台是锁屏 UI —— 可能是用户刚解锁但状态还没更新。
        XCTAssertFalse(LockEvidence.evaluate(stateLocked: false, sessionLocked: false, frontmostBundleID: "com.apple.loginwindow").locked)
    }

    func testTwoSignalsAreEnough() {
        XCTAssertTrue(LockEvidence.evaluate(stateLocked: true, sessionLocked: true, frontmostBundleID: "com.apple.Terminal").locked)
        XCTAssertTrue(LockEvidence.evaluate(stateLocked: true, sessionLocked: false, frontmostBundleID: "com.apple.loginwindow").locked)
        XCTAssertTrue(LockEvidence.evaluate(stateLocked: false, sessionLocked: true, frontmostBundleID: "com.apple.SecurityAgent").locked)
        XCTAssertTrue(LockEvidence.evaluate(stateLocked: true, sessionLocked: true, frontmostBundleID: "com.apple.ScreenSaver.Engine").locked)
    }

    /// 锁屏宿主进程是前台，但两个状态来源都说没锁 —— 只有一票，不注入。
    func testLockUIFrontmostAloneIsNotEnough() {
        for bundleID in LockEvidence.lockUIBundleIDs {
            let verdict = LockEvidence.evaluate(stateLocked: false, sessionLocked: false, frontmostBundleID: bundleID)
            XCTAssertFalse(verdict.locked, "\(bundleID) 单独一票不应放行")
            XCTAssertEqual(verdict.votes, 1)
        }
    }

    func testUnknownFrontmostIsNotALockUISignal() {
        XCTAssertEqual(LockEvidence.evaluate(stateLocked: false, sessionLocked: false, frontmostBundleID: nil).votes, 0)
        XCTAssertEqual(LockEvidence.evaluate(stateLocked: false, sessionLocked: false, frontmostBundleID: "com.example.unknown").votes, 0)
    }
}

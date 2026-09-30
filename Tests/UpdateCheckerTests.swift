import XCTest
@testable import MacBleUnlock

/// 只测能纯逻辑判定的部分：版本号比较。网络请求与下载不在这里测（会依赖 GitHub 状态）。
final class UpdateCheckerTests: XCTestCase {

    func testNumericSegmentsBeatStringOrder() {
        // 字符串字典序会给出 "1.0.10" < "1.0.9" 的错误结论，所以必须逐段比数字。
        XCTAssertTrue(UpdateChecker.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.9", than: "1.0.10"))
    }

    func testVPrefixIsIgnored() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.0.3", than: "1.0.2"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.0.2", than: "1.0.2"), "带不带 v 是同一个版本")
    }

    func testShorterVersionPadsWithZeros() {
        XCTAssertTrue(UpdateChecker.isNewer("1.1", than: "1.0.9"))
        XCTAssertTrue(UpdateChecker.isNewer("2", than: "1.99.99"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1"), "1.0 与 1 是同一个版本")
    }

    func testEqualVersionsAreNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0.2", than: "1.0.2"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.2.0", than: "1.0.2"))
    }

    func testPrereleaseSuffixIsTruncated() {
        // 段内的非数字后缀按截断处理：1.0.3-beta.1 的第三段取 3。
        XCTAssertTrue(UpdateChecker.isNewer("1.0.3-beta.1", than: "1.0.2"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.2-beta.1", than: "1.0.2"), "同号预发布不算更新")
    }

    func testUnparsableTagIsTreatedAsZero() {
        // tag 不按版本号命名时宁可当成「没有新版」：这是给用户看的提示，不能误报。
        XCTAssertFalse(UpdateChecker.isNewer("nightly", than: "1.0.2"))
    }
}

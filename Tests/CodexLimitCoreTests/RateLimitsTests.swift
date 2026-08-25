import Foundation
import Testing
@testable import CodexLimitCore

@Test func parsesFiveHourAndWeeklyWindows() throws {
    let json = #"""
    {"id":7,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1730947200},"secondary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":1731000000},"planType":"plus"}}}
    """#

    let decoded = try RateLimitSnapshot.decodeAppServerMessage(Data(json.utf8))
    let snapshot = try #require(decoded)
    #expect(snapshot.planType == "plus")
    #expect(snapshot.fiveHour?.remainingPercent == 75)
    #expect(snapshot.weekly?.remainingPercent == 90)
    #expect(snapshot.displayWindow == snapshot.fiveHour)
}

@Test func fallsBackToWeeklyWindow() throws {
    let json = #"""
    {"id":7,"result":{"rateLimits":{"primary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":1784986225},"secondary":null,"planType":"plus"}}}
    """#

    let decoded = try RateLimitSnapshot.decodeAppServerMessage(Data(json.utf8))
    let snapshot = try #require(decoded)
    #expect(snapshot.fiveHour == nil)
    #expect(snapshot.displayWindow == snapshot.weekly)
}

@Test func clampsRemainingPercent() {
    #expect(RateLimitWindow(usedPercent: -20, windowDurationMinutes: 300, resetsAt: nil).remainingPercent == 100)
    #expect(RateLimitWindow(usedPercent: 120, windowDurationMinutes: 300, resetsAt: nil).remainingPercent == 0)
}

@Test func selectsIndicatorColorsAtExactThresholds() {
    #expect(RateLimitIndicatorLevel(remainingPercent: 100) == .green)
    #expect(RateLimitIndicatorLevel(remainingPercent: 50) == .green)
    #expect(RateLimitIndicatorLevel(remainingPercent: 49.99) == .yellow)
    #expect(RateLimitIndicatorLevel(remainingPercent: 20) == .yellow)
    #expect(RateLimitIndicatorLevel(remainingPercent: 19.99) == .red)
    #expect(RateLimitIndicatorLevel(remainingPercent: 0) == .red)
}

@Test func selectsTheMostConstrainedWindow() {
    let snapshot = RateLimitSnapshot(planType: nil, windows: [
        RateLimitWindow(usedPercent: 20, windowDurationMinutes: 300, resetsAt: nil),
        RateLimitWindow(usedPercent: 85, windowDurationMinutes: 10_080, resetsAt: nil),
    ])
    #expect(snapshot.mostConstrainedWindow?.remainingPercent == 15)
}

@Test func parsesClaudeDesktopUsageHistory() throws {
    let json = #"""
    {"version":2,"samples":[
      {"t":1785620000000,"org":"org-1","u":{"fh":10,"sd":4}},
      {"t":1785620300000,"org":"org-1","u":{"fh":14,"sd":5}}
    ]}
    """#

    let decoded = try ClaudeUsageCache.decode(Data(json.utf8))
    let snapshot = try #require(decoded)
    #expect(snapshot.limits.fiveHour?.remainingPercent == 86)
    #expect(snapshot.limits.weekly?.remainingPercent == 95)
    #expect(snapshot.organizationID == "org-1")
    #expect(snapshot.lastUsageChangeAt == Date(timeIntervalSince1970: 1_785_620_300))
}

@Test func capturesClaudeCodeStatusLineLimitsWithoutSessionData() throws {
    let json = #"""
    {
      "session_id":"private-session",
      "workspace":{"current_dir":"/private/project"},
      "rate_limits":{
        "five_hour":{"used_percentage":23.5,"resets_at":1785630000},
        "seven_day":{"used_percentage":41.2,"resets_at":1786000000}
      }
    }
    """#
    let capturedAt = Date(timeIntervalSince1970: 1_785_620_500)
    let storedData = try ClaudeCodeUsageCache.updatedData(
        from: Data(json.utf8),
        previousData: nil,
        capturedAt: capturedAt
    )
    let stored = try #require(storedData)
    let decoded = try ClaudeCodeUsageCache.decode(stored)
    let snapshot = try #require(decoded)

    #expect(snapshot.limits.fiveHour?.remainingPercent == 76.5)
    #expect(snapshot.limits.weekly?.remainingPercent == 58.8)
    #expect(snapshot.limits.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_785_630_000))
    #expect(snapshot.lastUsageChangeAt == capturedAt)
    #expect(!String(decoding: stored, as: UTF8.self).contains("private-session"))
    #expect(!String(decoding: stored, as: UTF8.self).contains("private/project"))
}

@Test func preservesClaudeCodeActivityTimeWhenLimitsDoNotChange() throws {
    let json = #"""
    {"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1785630000}}}
    """#
    let firstDate = Date(timeIntervalSince1970: 1_785_620_500)
    let firstData = try ClaudeCodeUsageCache.updatedData(
        from: Data(json.utf8),
        previousData: nil,
        capturedAt: firstDate
    )
    let first = try #require(firstData)
    let secondData = try ClaudeCodeUsageCache.updatedData(
        from: Data(json.utf8),
        previousData: first,
        capturedAt: firstDate.addingTimeInterval(60)
    )
    let second = try #require(secondData)
    let decoded = try ClaudeCodeUsageCache.decode(second)
    let snapshot = try #require(decoded)

    #expect(snapshot.limits.fetchedAt == firstDate.addingTimeInterval(60))
    #expect(snapshot.lastUsageChangeAt == firstDate)
}

@Test func parsesClaudeCodeConfigUtilization() throws {
    let json = #"""
    {
      "userID":"private",
      "cachedUsageUtilization":{
        "fetchedAtMs":1785620000000,
        "accountUuid":"account-1",
        "utilization":{
          "five_hour":{"utilization":2,"resets_at":"2026-08-09T01:30:00.101754+00:00"},
          "seven_day":{"utilization":37.5,"resets_at":"2026-08-10T14:00:00.101778+00:00"},
          "seven_day_opus":null,
          "nimbus_quill":{"utilization":0,"resets_at":null},
          "extra_usage":{"is_enabled":false,"monthly_limit":null,"daily":null},
          "limits":[{"kind":"session","group":"session","percent":2,"resets_at":"2026-08-09T01:30:00.101754+00:00"}]
        }
      }
    }
    """#

    let decoded = try ClaudeConfigUsageCache.decode(Data(json.utf8))
    let snapshot = try #require(decoded)
    #expect(snapshot.accountID == "account-1")
    #expect(snapshot.limits.fetchedAt == Date(timeIntervalSince1970: 1_785_620_000))
    #expect(snapshot.limits.fiveHour?.remainingPercent == 98)
    #expect(snapshot.limits.weekly?.remainingPercent == 62.5)
    #expect(snapshot.limits.fiveHour?.resetsAt != nil)
    // Null meters and internal code names must not reach the dashboard.
    #expect(snapshot.limits.windows.count == 2)
}

@Test func returnsNoConfigSnapshotWithoutCachedUtilization() throws {
    #expect(try ClaudeConfigUsageCache.decode(Data(#"{"userID":"private"}"#.utf8)) == nil)
}

@Test func treatsAPassedResetAsAnEmptyWindow() {
    let now = Date(timeIntervalSince1970: 1_785_620_000)
    let snapshot = RateLimitSnapshot(planType: nil, windows: [
        RateLimitWindow(usedPercent: 91, windowDurationMinutes: 300, resetsAt: now.addingTimeInterval(-1)),
        RateLimitWindow(usedPercent: 40, windowDurationMinutes: 10_080, resetsAt: now.addingTimeInterval(3_600)),
    ], fetchedAt: now.addingTimeInterval(-7_200))

    let rolled = snapshot.rollingOver(at: now)
    #expect(rolled.fiveHour?.remainingPercent == 100)
    #expect(rolled.fiveHour?.resetsAt == nil)
    #expect(rolled.weekly?.remainingPercent == 60)
    #expect(rolled.weekly?.resetsAt == now.addingTimeInterval(3_600))
}

@Test func flagsWindowsThatCouldHaveResetUnnoticed() {
    let measuredAt = Date(timeIntervalSince1970: 1_785_620_000)
    let window = RateLimitWindow(usedPercent: 50, windowDurationMinutes: 300, resetsAt: nil)
    #expect(!window.couldHaveResetUnnoticed(measuredAt: measuredAt, now: measuredAt.addingTimeInterval(3_600)))
    #expect(window.couldHaveResetUnnoticed(measuredAt: measuredAt, now: measuredAt.addingTimeInterval(18_000)))

    let dated = RateLimitWindow(usedPercent: 50, windowDurationMinutes: 300, resetsAt: measuredAt)
    #expect(!dated.couldHaveResetUnnoticed(measuredAt: measuredAt, now: measuredAt.addingTimeInterval(90_000)))
}

@Test func keepsResetTimesWhenAFresherSourceOmitsThem() throws {
    let now = Date(timeIntervalSince1970: 1_785_620_000)
    // Desktop is the newest sample but never carries reset timestamps.
    let desktop = ClaudeUsageSnapshot(
        limits: RateLimitSnapshot(planType: nil, windows: [
            RateLimitWindow(identifier: "five_hour", usedPercent: 30, windowDurationMinutes: 300, resetsAt: nil),
        ], fetchedAt: now.addingTimeInterval(-60)),
        organizationID: "org-1",
        lastUsageChangeAt: now.addingTimeInterval(-60),
        source: .desktop
    )
    let code = ClaudeUsageSnapshot(
        limits: RateLimitSnapshot(planType: nil, windows: [
            RateLimitWindow(
                identifier: "five_hour",
                usedPercent: 25,
                windowDurationMinutes: 300,
                resetsAt: now.addingTimeInterval(1_800)
            ),
            RateLimitWindow(identifier: "seven_day", usedPercent: 10, windowDurationMinutes: 10_080, resetsAt: nil),
        ], fetchedAt: now.addingTimeInterval(-600)),
        organizationID: nil,
        lastUsageChangeAt: now.addingTimeInterval(-600),
        source: .claudeCode
    )

    let merged = try #require(ClaudeUsageSnapshot.merged([code, desktop], at: now))
    #expect(merged.source == .desktop)
    #expect(merged.organizationID == "org-1")
    // The fresher percentage wins, the older reset time fills the gap.
    #expect(merged.limits.fiveHour?.usedPercent == 30)
    #expect(merged.limits.fiveHour?.resetsAt == now.addingTimeInterval(1_800))
    // A window only the older source knows about is still reported.
    #expect(merged.limits.weekly?.usedPercent == 10)
    #expect(merged.lastUsageChangeAt == now.addingTimeInterval(-60))
}

@Test func doesNotBackfillAResetTimeThatAlreadyPassed() throws {
    let now = Date(timeIntervalSince1970: 1_785_620_000)
    let desktop = ClaudeUsageSnapshot(
        limits: RateLimitSnapshot(planType: nil, windows: [
            RateLimitWindow(identifier: "five_hour", usedPercent: 30, windowDurationMinutes: 300, resetsAt: nil),
        ], fetchedAt: now.addingTimeInterval(-60)),
        organizationID: nil,
        lastUsageChangeAt: nil,
        source: .desktop
    )
    let code = ClaudeUsageSnapshot(
        limits: RateLimitSnapshot(planType: nil, windows: [
            RateLimitWindow(
                identifier: "five_hour",
                usedPercent: 90,
                windowDurationMinutes: 300,
                resetsAt: now.addingTimeInterval(-1)
            ),
        ], fetchedAt: now.addingTimeInterval(-7_200)),
        organizationID: nil,
        lastUsageChangeAt: nil,
        source: .claudeCode
    )

    let merged = try #require(ClaudeUsageSnapshot.merged([code, desktop], at: now))
    // That window already rolled over, so its old reset must not be reattached —
    // doing so would have wiped the fresher 30% as if the quota were empty.
    #expect(merged.limits.fiveHour?.usedPercent == 30)
    #expect(merged.limits.fiveHour?.resetsAt == nil)
}

@Test func reportsRecencyWithoutDiscardingOlderNumbers() {
    let now = Date(timeIntervalSince1970: 1_785_620_000)
    let snapshot = ClaudeUsageSnapshot(
        limits: RateLimitSnapshot(planType: nil, windows: [
            RateLimitWindow(
                identifier: "five_hour",
                usedPercent: 30,
                windowDurationMinutes: 300,
                resetsAt: now.addingTimeInterval(3_600)
            ),
        ], fetchedAt: now.addingTimeInterval(-16 * 60)),
        organizationID: nil,
        lastUsageChangeAt: nil,
        source: .desktop
    )
    // A 16-minute-old desktop sample is normal, not stale.
    #expect(snapshot.isRecent(at: now))
    #expect(!snapshot.hasUnverifiableWindow(at: now))
    #expect(!snapshot.isRecent(at: now.addingTimeInterval(30 * 60)))
}

@Test func parsesChatGPTAccountWithoutCredentials() throws {
    let json = #"""
    {"id":8,"result":{"account":{"type":"chatgpt","email":"user@example.com","planType":"plus"},"requiresOpenaiAuth":true}}
    """#

    let decoded = try CodexAccount.decodeAppServerMessage(Data(json.utf8))
    let account = try #require(decoded)
    #expect(account.kind == .chatgpt)
    #expect(account.email == "user@example.com")
    #expect(account.planType == "plus")
}

@Test func returnsNoAccountWhenSignedOut() throws {
    let json = #"""
    {"id":8,"result":{"account":null,"requiresOpenaiAuth":true}}
    """#

    let account = try CodexAccount.decodeAppServerMessage(Data(json.utf8))
    #expect(account == nil)
}

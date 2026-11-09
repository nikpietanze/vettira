import Foundation
import Testing
import VettiraCore

// Expected values come from the spec ("Local notifications": ticker, price, current session high,
// drop from high, signal type and quote timestamp, never an instruction to sell) and AGENTS.md
// (a possible reversal, never advice or certainty; an observed high is called the observed high).

@Test func aNotificationIsAPossibleReversalWithEverythingTheSpecAsksFor() {
    let notification = AlertNotification(earlyWarning(), timeZone: newYork)
    #expect(notification.title == "SPY: possible reversal, not confirmed")
    #expect(notification.subtitle == "Early warning (0.25% threshold)")
    #expect(notification.body == "100.20 is 0.30% below the observed high of 100.50. "
        + "Quote at 10:00:15 EST, 5 s old, from Test provider.")
    #expect(notification.threadIdentifier == "SPY")
}

@Test func aNotificationNeverReadsAsAdviceOrCertainty() {
    let notification = AlertNotification(earlyWarning(), timeZone: newYork)
    let text = [notification.title, notification.subtitle, notification.body].joined(separator: " ").lowercased()
    for word in ["sell", "buy", "confirmed reversal", "signal to", "should"] {
        #expect(!text.contains(word), "\(word)")
    }
}

/// A notification center that answers as told and keeps what it's asked.
private final class FakeCenter: AlertNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var status: NotificationAuthorization
    private let answer: NotificationAuthorization
    private let failure: (any Error)?
    private var _requests = 0
    private var _posted: [(AlertNotification, Bool)] = []

    init(_ status: NotificationAuthorization, answer: NotificationAuthorization = .allowed, failure: (any Error)? = nil) {
        self.status = status
        self.answer = answer
        self.failure = failure
    }

    var requests: Int { lock.withLock { _requests } }
    var posted: [(AlertNotification, Bool)] { lock.withLock { _posted } }

    func authorization() async -> NotificationAuthorization { lock.withLock { status } }

    func requestAuthorization() async -> NotificationAuthorization {
        lock.withLock {
            _requests += 1
            status = answer
            return answer
        }
    }

    func add(_ notification: AlertNotification, sound: Bool) async throws {
        if let failure { throw failure }
        lock.withLock { _posted.append((notification, sound)) }
    }
}

@Test func theFirstAlertAsksForPermissionThenPosts() async {
    let center = FakeCenter(.notDetermined)
    let delivery = AlertDelivery(center: center, timeZone: newYork)
    #expect(await delivery.deliver(earlyWarning(), sound: true) == .delivered)
    #expect(await delivery.deliver(earlyWarning(), sound: false) == .delivered)
    #expect(center.requests == 1)
    #expect(center.posted.map(\.0.title) == ["SPY: possible reversal, not confirmed", "SPY: possible reversal, not confirmed"])
    #expect(center.posted.map(\.1) == [true, false])
}

@Test func deniedNotificationsArentPostedOrAskedForAgain() async {
    let center = FakeCenter(.notDetermined, answer: .denied)
    let delivery = AlertDelivery(center: center)
    #expect(await delivery.deliver(earlyWarning(), sound: true) == .denied)
    #expect(await delivery.deliver(earlyWarning(), sound: true) == .denied)
    #expect(center.requests == 1)
    #expect(center.posted.isEmpty)
}

@Test func authorizingAsksOnlyWhenNobodyHasAsked() async {
    let asked = FakeCenter(.allowed)
    #expect(await AlertDelivery(center: asked).authorize() == .allowed)
    #expect(asked.requests == 0)
    let fresh = FakeCenter(.notDetermined, answer: .denied)
    #expect(await AlertDelivery(center: fresh).authorize() == .denied)
    #expect(fresh.requests == 1)
}

private struct Refused: LocalizedError {
    var errorDescription: String? { "refused" }
}

@Test func aNotificationTheSystemRefusesSaysWhy() async {
    let delivery = AlertDelivery(center: FakeCenter(.allowed, failure: Refused()))
    #expect(await delivery.deliver(earlyWarning(), sound: true) == .failed("refused"))
}

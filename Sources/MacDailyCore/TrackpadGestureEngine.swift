import Foundation

/// Coordinates are normalized to the touch surface; Y increases toward its top.
public struct TrackpadContact: Equatable, Sendable {
    public var id: Int32
    public var x: Double
    public var y: Double
    public init(id: Int32, x: Double, y: Double) { self.id = id; self.x = x; self.y = y }
}

public struct TrackpadFrame: Sendable {
    public var contacts: [TrackpadContact]
    public var timestamp: Double
    public var modifiers: UInt64
    public var bundleIdentifier: String
    public var isTitlebar: Bool
    public init(contacts: [TrackpadContact], timestamp: Double, modifiers: UInt64 = 0,
                bundleIdentifier: String = "", isTitlebar: Bool = false) {
        self.contacts = contacts; self.timestamp = timestamp; self.modifiers = modifiers
        self.bundleIdentifier = bundleIdentifier; self.isTitlebar = isTitlebar
    }
}

public enum TrackpadCaptureKind: String, Sendable {
    case threeFinger, fourFinger, corner, titlebar
}

public struct TrackpadRecognition: Sendable {
    public var gesture: TrackpadGesture?
    public var preview: TrackpadGesture?
    public var binding: TrackpadBinding?
    public var feedback: String?
    public var shouldSuppressScroll: Bool
    public var shouldSuppressClick: Bool
    public var sessionStarted: Bool
    public var sessionEnded: Bool
    public var captureKind: TrackpadCaptureKind?
    public init(gesture: TrackpadGesture? = nil, preview: TrackpadGesture? = nil,
                binding: TrackpadBinding? = nil, feedback: String? = nil,
                shouldSuppressScroll: Bool = false, shouldSuppressClick: Bool = false,
                sessionStarted: Bool = false, sessionEnded: Bool = false,
                captureKind: TrackpadCaptureKind? = nil) {
        self.gesture = gesture; self.preview = preview; self.binding = binding; self.feedback = feedback
        self.shouldSuppressScroll = shouldSuppressScroll; self.shouldSuppressClick = shouldSuppressClick
        self.sessionStarted = sessionStarted; self.sessionEnded = sessionEnded; self.captureKind = captureKind
    }
}

public struct TrackpadGestureEngine: Sendable {
    private struct Session: Sendable {
        var bundle: String
        var modifiers: UInt64
        var peakCount: Int
        var peakTime: Double
        var baseline: [Int32: TrackpadContact]
        var current: [Int32: TrackpadContact]
        var maxMovement: Double = 0
        var tapRejected = false
        var released = false
        var titlebar = false
        var corner: TrackpadGesture?
    }
    private var settings: TrackpadSettings
    private var session: Session?
    private var waitingForLift = false
    public private(set) var capturedKind: TrackpadCaptureKind?
    public var isCapturing: Bool { capturedKind != nil }

    public init(settings: TrackpadSettings = TrackpadSettings()) { self.settings = settings }
    public mutating func update(settings: TrackpadSettings) {
        cancel(); self.settings = settings
    }
    public mutating func cancel() {
        waitingForLift = session != nil || waitingForLift
        session = nil; capturedKind = nil
    }
    /// A stopped device stream has no remaining contact lifetime to drain.
    public mutating func reset() {
        session = nil; capturedKind = nil; waitingForLift = false
    }

    public mutating func process(_ frame: TrackpadFrame, native: NativeTrackpadStatus) -> TrackpadRecognition {
        if waitingForLift {
            if frame.contacts.isEmpty { waitingForLift = false }
            return TrackpadRecognition()
        }
        guard frame.timestamp.isFinite else { cancel(); return TrackpadRecognition(feedback: L10n.text("已取消手势")) }
        if let current = session,
           frame.bundleIdentifier != current.bundle || frame.modifiers != current.modifiers {
            session = nil; capturedKind = nil; waitingForLift = !frame.contacts.isEmpty
            return TrackpadRecognition(feedback: L10n.text("应用或修饰键已切换，手势取消"), sessionEnded: true)
        }
        if settings.excludes(frame.bundleIdentifier) {
            session = nil; capturedKind = nil
            return TrackpadRecognition()
        }
        if frame.contacts.isEmpty {
            guard let current = session else { return TrackpadRecognition() }
            let endingKind = capturedKind
            defer { session = nil; capturedKind = nil }
            let elapsed = frame.timestamp - current.peakTime
            var candidate: TrackpadGesture?
            if current.peakCount == 1, let corner = current.corner,
               elapsed >= 0, elapsed <= settings.tapDuration, current.maxMovement <= settings.tapMovement {
                candidate = corner
            } else if current.peakCount == 3 || current.peakCount == 4 {
                if elapsed >= 0, elapsed <= settings.tapDuration, current.maxMovement <= settings.tapMovement, !current.tapRejected {
                    candidate = current.peakCount == 3 ? .threeTap : .fourTap
                } else if current.peakCount == 3 { candidate = direction(for: current) }
            } else if current.peakCount == 2 && current.titlebar { candidate = direction(for: current) }
            guard let candidate else {
                return TrackpadRecognition(feedback: endingKind == nil ? nil : L10n.text("未达到轻点或滑动条件"), sessionEnded: true)
            }
            guard let binding = eligible(candidate, session: current, native: native) else {
                return TrackpadRecognition(feedback: native.conflict(for: candidate) ?? L10n.text("该手势未启用映射"), sessionEnded: true)
            }
            return TrackpadRecognition(gesture: candidate, binding: binding,
                                       feedback: "\(candidate.title) → \(binding.action.title)",
                                       shouldSuppressScroll: endingKind == .threeFinger || endingKind == .titlebar,
                                       shouldSuppressClick: candidate == .threeTap || candidate == .fourTap || candidate.isCorner,
                                       sessionEnded: true, captureKind: endingKind)
        }

        let started = session == nil
        if session == nil {
            let contacts = Dictionary(frame.contacts.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            session = Session(bundle: frame.bundleIdentifier, modifiers: frame.modifiers,
                              peakCount: frame.contacts.count, peakTime: frame.timestamp,
                              baseline: contacts, current: contacts,
                              titlebar: frame.isTitlebar,
                              corner: frame.contacts.count == 1 ? corner(at: frame.contacts[0]) : nil)
        }
        guard var current = session else { return TrackpadRecognition() }
        let count = frame.contacts.count
        // Once fingers start lifting, they cannot re-enter a new gesture without
        // a full release. This also preserves a four-finger tap across staggered lifts.
        if count < current.peakCount { current.released = true }
        if count > current.peakCount && !current.released {
            if current.peakCount >= 3 && current.maxMovement > settings.tapMovement { current.tapRejected = true }
            current.peakCount = count; current.peakTime = frame.timestamp
            current.baseline = Dictionary(frame.contacts.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            current.current = current.baseline; current.maxMovement = 0
            current.titlebar = frame.isTitlebar; current.corner = nil
        } else if count == current.peakCount && !current.released {
            let contacts = Dictionary(frame.contacts.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            if Set(contacts.keys) != Set(current.baseline.keys) {
                session = nil; capturedKind = nil; waitingForLift = true
                return TrackpadRecognition(feedback: L10n.text("触点已变化，手势取消"), sessionEnded: true)
            }
            current.current = contacts
            for (id, contact) in contacts {
                if let origin = current.baseline[id] {
                    current.maxMovement = max(current.maxMovement, hypot(contact.x - origin.x, contact.y - origin.y))
                }
            }
            // The AX titlebar lookup can complete after the first two-finger frame.
            if current.peakCount == 2 { current.titlebar = current.titlebar || frame.isTitlebar }
        }
        session = current
        let tapEligible = current.maxMovement <= settings.tapMovement && !current.tapRejected
        var candidates: [TrackpadGesture]
        switch current.peakCount {
        case 1: candidates = tapEligible ? current.corner.map { [$0] } ?? [] : []
        case 2: candidates = current.titlebar ? [.titlebarLeft, .titlebarRight, .titlebarUp, .titlebarDown] : []
        case 3: candidates = (tapEligible ? [.threeTap] : []) + [.threeLeft, .threeRight, .threeUp, .threeDown]
        case 4: candidates = tapEligible ? [.fourTap] : []
        default: candidates = []
        }
        if let direction = direction(for: current) { candidates = [direction] }
        let available = candidates.filter { eligible($0, session: current, native: native) != nil }
        if available.isEmpty { capturedKind = nil }
        else {
            switch current.peakCount {
            case 1: capturedKind = .corner
            case 2: capturedKind = .titlebar
            case 3: capturedKind = .threeFinger
            case 4: capturedKind = .fourFinger
            default: capturedKind = nil
            }
        }
        let preview = direction(for: current).flatMap { eligible($0, session: current, native: native) == nil ? nil : $0 }
        let directionOwned = available.contains { $0 != .threeTap && $0 != .fourTap && !$0.isCorner }
        let conflict = candidates.compactMap { candidate -> String? in
            guard settings.binding(for: candidate, modifiers: current.modifiers, bundleIdentifier: current.bundle) != nil else { return nil }
            return native.conflict(for: candidate)
        }.first
        return TrackpadRecognition(preview: preview,
                                   feedback: started || (capturedKind == nil && conflict != nil) ? conflict : nil,
                                   shouldSuppressScroll: directionOwned && (capturedKind == .threeFinger || capturedKind == .titlebar),
                                   shouldSuppressClick: available.contains { $0 == .threeTap || $0 == .fourTap || $0.isCorner },
                                   sessionStarted: started, captureKind: capturedKind)
    }

    private func eligible(_ gesture: TrackpadGesture, session: Session, native: NativeTrackpadStatus) -> TrackpadBinding? {
        guard native.conflict(for: gesture) == nil else { return nil }
        return settings.binding(for: gesture, modifiers: session.modifiers, bundleIdentifier: session.bundle)
    }
    private func corner(at contact: TrackpadContact) -> TrackpadGesture? {
        let left = contact.x <= settings.cornerSize
        let right = contact.x >= 1 - settings.cornerSize
        let top = contact.y >= 1 - settings.cornerSize
        let bottom = contact.y <= settings.cornerSize
        if left && top { return .cornerTopLeft }
        if right && top { return .cornerTopRight }
        if left && bottom { return .cornerBottomLeft }
        if right && bottom { return .cornerBottomRight }
        return nil
    }
    private func direction(for session: Session) -> TrackpadGesture? {
        guard session.peakCount == 3 || (session.peakCount == 2 && session.titlebar), !session.baseline.isEmpty else { return nil }
        let count = Double(session.baseline.count)
        let dx = session.baseline.reduce(0.0) { sum, pair in sum + ((session.current[pair.key]?.x ?? pair.value.x) - pair.value.x) } / count
        let dy = session.baseline.reduce(0.0) { sum, pair in sum + ((session.current[pair.key]?.y ?? pair.value.y) - pair.value.y) } / count
        let horizontal = abs(dx) >= settings.swipeDistance && abs(dx) >= abs(dy) * settings.axisDominance
            && session.baseline.allSatisfy { id, origin in
                let movement = (session.current[id]?.x ?? origin.x) - origin.x
                return movement * dx > 0 && abs(movement) >= settings.swipeDistance * 0.5
            }
        let vertical = abs(dy) >= settings.swipeDistance && abs(dy) >= abs(dx) * settings.axisDominance
            && session.baseline.allSatisfy { id, origin in
                let movement = (session.current[id]?.y ?? origin.y) - origin.y
                return movement * dy > 0 && abs(movement) >= settings.swipeDistance * 0.5
            }
        if session.peakCount == 3 {
            if horizontal { return dx < 0 ? .threeLeft : .threeRight }
            if vertical { return dy > 0 ? .threeUp : .threeDown }
        } else {
            if horizontal { return dx < 0 ? .titlebarLeft : .titlebarRight }
            if vertical { return dy > 0 ? .titlebarUp : .titlebarDown }
        }
        return nil
    }
}

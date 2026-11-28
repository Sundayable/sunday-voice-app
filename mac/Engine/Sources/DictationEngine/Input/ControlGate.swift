import Foundation

/// Observes Control without consuming any keyboard event. A chord always wins.
struct ControlGate {
    enum Action: Equatable { case none, start, stop, cancel }
    private(set) var down = false
    private var deadline: Double?
    private var active = false
    private var blocked = false
    var isActive: Bool { active }

    mutating func modifiers(control: Bool, other: Bool, keysDown: Bool, now: Double, delay: Double) -> Action {
        if !control {
            let result: Action = active ? .stop : .none
            down=false; deadline=nil; active=false; blocked=false
            return result
        }
        if !down {
            down=true; blocked=other || keysDown
            deadline=blocked ? nil : now+delay
        }
        return (other || keysDown) ? interfere() : .none
    }
    mutating func interfere() -> Action {
        guard down else { return .none }
        let result: Action = active ? .cancel : .none
        active=false; deadline=nil; blocked=true
        return result
    }
    /// Blocks an unstarted hold (e.g. Control+Scroll zoom before the hold delay), without ever cancelling active speech.
    mutating func blockBeforeStart() {
        guard down, !active else { return }
        deadline = nil; blocked = true
    }
    mutating func poll(now: Double) -> Action {
        guard down,!blocked,!active,let limit=deadline,now>=limit else {return .none}
        deadline=nil;active=true;return .start
    }
    mutating func reset() {self=ControlGate()}
}

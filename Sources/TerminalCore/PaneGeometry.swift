import Foundation

public enum PaneResizeDirection { case left, right, up, down }
public struct PaneResizeTarget {
    public let splitID: String
    public let ratio: Double
}

extension PaneTree {
    public func resizeTarget(paneID: String, direction: PaneResizeDirection) -> PaneResizeTarget? {
        switch self {
        case .pane: return nil
        case .split(let id, let axis, let ratio, let first, let second):
            let inFirst = first.panes.contains(paneID)
            guard inFirst || second.panes.contains(paneID) else { return nil }
            let child = inFirst ? first : second
            if let target = child.resizeTarget(paneID: paneID, direction: direction) { return target }
            let horizontal = direction == .left || direction == .right
            guard (axis == .horizontal) == horizontal else { return nil }
            let delta = direction == .left || direction == .up ? -0.05 : 0.05
            return PaneResizeTarget(splitID: id, ratio: min(0.85, max(0.15, ratio + delta)))
        }
    }
}

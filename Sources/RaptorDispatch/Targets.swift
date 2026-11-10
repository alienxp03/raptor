import Foundation
import RaptorConfig
import RaptorRex

public extension RaptorDispatch {
    static func targetLabel(_ t: String) -> String {
        switch t {
        case "session":
            return "session"
        case "tab":
            return "tab"
        case "pane_right":
            return "pane →"
        case "pane_below":
            return "pane ↓"
        case "here":
            return "cd here"
        default:
            return t
        }
    }

    static func splitDirection(_ target: String) -> String {
        switch target {
        case "pane_right":
            return "right"
        case "pane_below":
            return "below"
        default:
            return ""
        }
    }

    static func nextTarget(cfg: RaptorConfig, cur: String, forward: Bool) -> String {
        var list = cfg.targets
        if list.isEmpty {
            list = RaptorConfig.default().targets
        }
        var idx = 0
        for (i, t) in list.enumerated() where t == cur {
            idx = i
            break
        }
        let step = forward ? 1 : -1
        idx = ((idx + step) % list.count + list.count) % list.count
        return list[idx]
    }

    static func headerTargets(cfg: RaptorConfig, cur: String) -> String {
        cfg.targets.map { t -> String in
            let lbl = targetLabel(t)
            return t == cur ? "[" + lbl + "]" : lbl
        }
        .joined(separator: " ")
    }
}

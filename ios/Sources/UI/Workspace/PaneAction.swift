import Foundation
import GhosttyKit

/// Tab and split actions a pane asks for, from Ghostty keybinds or the
/// toolbar. These mirror Ghostty's binding actions of the same names.
enum PaneAction: Equatable {
    enum TabTarget: Equatable {
        /// 1-based, like `goto_tab:N`; past the end means the last tab.
        case index(Int)
        case previous, next, last
    }

    enum SplitTarget: Equatable {
        case previous, next
        case toward(SplitDirection)
    }

    enum CloseTabMode: Equatable { case this, others, right }

    case newTab
    /// Nil splits the way that suits the screen's orientation.
    case newSplit(SplitDirection?)
    case gotoSplit(SplitTarget)
    /// `amount` in points, as Ghostty's `resize_split`.
    case resizeSplit(SplitDirection, amount: Double)
    case equalizeSplits
    case toggleSplitZoom
    case gotoTab(TabTarget)
    case closeTab(CloseTabMode)
    case closeWindow

    /// Translate a libghostty action, or nil if it isn't a tab/split one.
    init?(_ action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_NEW_TAB:
            self = .newTab
        case GHOSTTY_ACTION_NEW_SPLIT:
            self = .newSplit(SplitDirection(action.action.new_split))
        case GHOSTTY_ACTION_GOTO_SPLIT:
            switch action.action.goto_split {
            case GHOSTTY_GOTO_SPLIT_PREVIOUS: self = .gotoSplit(.previous)
            case GHOSTTY_GOTO_SPLIT_NEXT: self = .gotoSplit(.next)
            case GHOSTTY_GOTO_SPLIT_UP: self = .gotoSplit(.toward(.up))
            case GHOSTTY_GOTO_SPLIT_DOWN: self = .gotoSplit(.toward(.down))
            case GHOSTTY_GOTO_SPLIT_LEFT: self = .gotoSplit(.toward(.left))
            default: self = .gotoSplit(.toward(.right))
            }
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            let resize = action.action.resize_split
            let direction: SplitDirection
            switch resize.direction {
            case GHOSTTY_RESIZE_SPLIT_UP: direction = .up
            case GHOSTTY_RESIZE_SPLIT_DOWN: direction = .down
            case GHOSTTY_RESIZE_SPLIT_LEFT: direction = .left
            default: direction = .right
            }
            self = .resizeSplit(direction, amount: Double(resize.amount))
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            self = .equalizeSplits
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            self = .toggleSplitZoom
        case GHOSTTY_ACTION_GOTO_TAB:
            switch action.action.goto_tab {
            case GHOSTTY_GOTO_TAB_PREVIOUS: self = .gotoTab(.previous)
            case GHOSTTY_GOTO_TAB_NEXT: self = .gotoTab(.next)
            case GHOSTTY_GOTO_TAB_LAST: self = .gotoTab(.last)
            default: self = .gotoTab(.index(Int(action.action.goto_tab.rawValue)))
            }
        case GHOSTTY_ACTION_CLOSE_TAB:
            switch action.action.close_tab_mode {
            case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER: self = .closeTab(.others)
            case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT: self = .closeTab(.right)
            default: self = .closeTab(.this)
            }
        case GHOSTTY_ACTION_CLOSE_WINDOW:
            self = .closeWindow
        default:
            return nil
        }
    }
}

extension SplitDirection {
    init(_ direction: ghostty_action_split_direction_e) {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_LEFT: self = .left
        case GHOSTTY_SPLIT_DIRECTION_UP: self = .up
        case GHOSTTY_SPLIT_DIRECTION_DOWN: self = .down
        default: self = .right
        }
    }
}

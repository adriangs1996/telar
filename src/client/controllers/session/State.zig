const State = @This();

phase: enum { inactive, probing, opening, active } = .inactive,

/// Example: `if (state.holdsInput()) retainKeystrokes();`.
pub fn holdsInput(state: State) bool {
    return state.phase == .probing or state.phase == .opening;
}

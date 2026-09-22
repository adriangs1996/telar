const StartupState = @This();

phase: enum { inactive, probing, opening, active } = .inactive,

/// Example: `if (state.holdsInput()) retainKeystrokes();`.
pub fn holdsInput(self: StartupState) bool {
    return self.phase == .probing or self.phase == .opening;
}

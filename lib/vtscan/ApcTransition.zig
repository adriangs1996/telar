//! What one step of `ApcFraming` saw happen to a Kitty graphics command.
pub const ApcTransition = enum {
    /// The `G` that makes an APC a Kitty command; its content follows.
    kitty_started,
    /// The byte that ended a Kitty command, aborted or not: Ghostty runs it
    /// either way.
    kitty_ended,
};

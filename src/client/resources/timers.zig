//! The replaceable client timers an adapter arms on its own event loop.

/// Which completion the adapter must deliver when the deadline passes.
pub const Kind = enum {
    input,
    binding,
    bar,
    notification,
    sidebar_animation,
};

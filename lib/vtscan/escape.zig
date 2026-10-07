//! Escape-sequence scanners shared by the backend.
//!
//! Three small byte-at-a-time automata live here so their subtle rules -
//! what terminates a string, what a stray ESC means, which C1 bytes are
//! real controls - are decided once, tested once, and preserved across
//! arbitrary read boundaries as the parser invariants require.
//!
//! None of these is the emulator: ghostty alone defines what a screen is.
//! These recognizers only frame byte streams for accounting (KGP chunk
//! counting), history capture (OSC payloads), and input classification
//! (submits and bracketed paste).

pub const esc = 0x1b;

pub const bel = 0x07;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

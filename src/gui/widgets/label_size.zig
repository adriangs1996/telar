//! Which of the chrome's text sizes a sans label is set at. `terminal` is
//! the cell's own glyph size, so callers that never chose keep their
//! glyphs; the three roles come from `ChromeMetrics` and scale with
//! `gui.chrome.scale`. Monospace labels always use the terminal grid.
pub const Size = enum(u2) {
    terminal,
    /// The card title.
    title,
    /// Headers, pills, tabs, pane headers, palette rows and form labels.
    body,
    /// Card context rows, footers, the status glyph and chips.
    small,
};

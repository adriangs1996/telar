const Metrics = @This();

border: u8 = 1,
gap: u8 = 1,

/// Example: `const width = metrics.minimumPaneExtent();`.
pub fn minimumPaneExtent(self: Metrics) u16 {
    return 1 + 2 * @as(u16, self.border);
}

/// Example: `const gutter = metrics.gutter(pane_gaps);`.
pub fn gutter(self: Metrics, enabled: bool) u16 {
    return if (enabled) self.gap else 0;
}

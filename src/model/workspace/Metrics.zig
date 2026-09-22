const Metrics = @This();

border: u8 = 1,
gap: u8 = 1,

/// Example: `const width = metrics.minimumPaneExtent();`.
pub fn minimumPaneExtent(metrics: Metrics) u16 {
    return 1 + 2 * @as(u16, metrics.border);
}

/// Example: `const gutter = metrics.gutter(pane_gaps);`.
pub fn gutter(metrics: Metrics, enabled: bool) u16 {
    return if (enabled) metrics.gap else 0;
}

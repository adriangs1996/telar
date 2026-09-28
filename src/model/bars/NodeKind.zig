//! The closed vocabulary of components a configuration can compose. Inline
//! kinds fit in a bar row; block kinds stack vertically inside a panel.
pub const NodeKind = enum(u8) {
    label,
    icon,
    mark,
    meter,
    sparkline,
    badge,
    clock,
    metric,
    group,
    heading,
    text,
    meter_row,
    kv,
    callout,
    actions,
    button,
    divider,

    /// Whether the kind may appear in a bar slot, a group or a tooltip.
    /// Example: `if (!kind.isInline()) return error.BlockComponentInBar;`
    pub fn isInline(self: NodeKind) bool {
        return switch (self) {
            .label, .icon, .mark, .meter, .sparkline, .badge, .clock, .metric, .group => true,
            else => false,
        };
    }

    /// Whether the kind holds other components.
    /// Example: `if (kind.isContainer()) parent = index;`
    pub fn isContainer(self: NodeKind) bool {
        return switch (self) {
            .group, .callout, .actions => true,
            else => false,
        };
    }
};

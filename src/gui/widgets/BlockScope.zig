//! Which nodes of a list form one stack: the roots of a panel, or the
//! tooltip children of one bar group.
const data = @import("model");
const BlockScope = @This();

parent: u8 = data.Node.no_parent,
tooltip: bool = false,
/// Registers buttons as panel targets; tooltips only paint.
interactive: bool = false,

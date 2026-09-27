//! A name prompt about the window's machines: renaming one, or the two steps
//! of adding one, its label and then its SSH destination.
const MachineLabel = @import("MachineLabel.zig");

pub const MachinePrompt = union(enum) {
    /// Renames the machine in a window slot.
    rename: u8,
    /// Asks for the new machine's label.
    add_label,
    /// Asks for its destination, holding the label typed before.
    add_destination: MachineLabel,
};

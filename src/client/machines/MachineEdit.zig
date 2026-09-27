//! One change to `machines.json`, as `telar machine` and the window's
//! machine picker both make it. The slices are borrowed until the change is
//! applied.
const MachineEdit = @This();

pub const Kind = enum {
    add,
    remove,
    rename,
    enable,
    disable,
};

kind: Kind,
/// The machine's label; the new machine's label for `add`.
label: []const u8,
/// The new label for `rename`, the destination for `add`, unused otherwise.
value: []const u8 = "",
/// The new machine's color, for `add` only.
color: ?[]const u8 = null,

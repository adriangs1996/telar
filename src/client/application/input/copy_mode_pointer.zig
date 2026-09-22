//! Application policy for keyboard copy mode and captured mouse selections.

const core = @import("telar-core");

pub const Authority = union(enum) {
    unowned,
    target_missing,
    selection: struct {
        dragging: bool,
        position: ?core.Point,
    },
    owned: struct {
        pointer_inside: bool,
    },
};

pub const Outcome = enum {
    unowned,
    consumed,
    moved,
    exited,
};

pub const Event = enum {
    leave,
    vertical,
    pointer,
    cancel_pointer,
};

pub const Failure = enum {
    none,
    leave,
    vertical,
};

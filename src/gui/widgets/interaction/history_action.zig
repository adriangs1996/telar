//! Native history controls keep selection separate from command submission.

pub const Action = union(enum) {
    select: struct { index: u16, revision: u64 },
    submit: struct { index: u16, revision: u64 },
    cycle_scope,
    toggle_inspection,
};

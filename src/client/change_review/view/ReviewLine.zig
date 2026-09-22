const core = @import("telar-core");

value: core.ChangeReviewDiffLine,
offset: usize,
file: usize,
hunk: usize,

pub fn before(self: *const @This()) bool {
    return self.value.kind == .removed;
}

const Line = @import("telar-core").ChangeReviewDiffLine;

value: Line,
offset: usize,
file: usize,
hunk: usize,

pub fn before(self: *const @This()) bool {
    return self.value.kind == .removed;
}

const Plan = @This();
const source_namespace = @import("icons.zig");
const Mark = @import("Mark.zig");
marks: [source_namespace.max_marks]Mark = undefined,
len: u8 = 0,

pub fn reset(plan: *Plan) void {
    plan.len = 0;
}

pub fn add(plan: *Plan, mark: Mark) void {
    if (plan.len == plan.marks.len) {
        return;
    }
    plan.marks[plan.len] = mark;
    plan.len += 1;
}

pub fn slice(plan: *const Plan) []const Mark {
    return plan.marks[0..plan.len];
}

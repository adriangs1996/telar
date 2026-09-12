const std = @import("std");
const Application = @import("build/Application.zig");
const Benchmarks = @import("build/Benchmarks.zig");
const experiments = @import("build/experiments.zig");
const packaging = @import("build/packaging.zig");
const gui = @import("build/gui.zig");
const tests = @import("build/tests.zig");
const cross = @import("build/cross.zig");

pub fn build(b: *std.Build) void {
    var app = Application.init(b) orelse return;
    const bench = Benchmarks.init(b, app);
    experiments.add(b, app);
    packaging.add(b, app);
    app.modules.gui = gui.add(b, app);
    const parallel_tests = tests.add(b, app, bench);
    parallel_tests.dependOn(cross.add(b));
}

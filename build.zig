const run_widget = @import("run_widget.zig");
const std = @import("std");
const Application = @import("build/Application.zig");
const Benchmarks = @import("build/Benchmarks.zig");
const packaging = @import("build/packaging.zig");
const gui = @import("build/gui.zig");
const checks = @import("build/checks.zig");
const cross = @import("build/cross.zig");
const diagram_renderer = @import("build/diagram_renderer.zig");
const headless = @import("build/headless.zig");

pub fn build(b: *std.Build) void {
    var app = Application.init(b) orelse return;
    const bench = Benchmarks.init(b, app);
    const diagram_helper = diagram_renderer.add(b, app);
    packaging.add(b, app, diagram_helper);
    app.modules.gui = gui.add(b, app, diagram_helper);
    run_widget.addBuild(b, app);
    headless.add(b, app);
    checks.add(b, app, bench, cross.add(b));
}

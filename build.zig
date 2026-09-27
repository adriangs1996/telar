const run_widget = @import("run_widget.zig");
const std = @import("std");
const Application = @import("build/Application.zig");
const Benchmarks = @import("build/Benchmarks.zig");
const experiments = @import("build/experiments.zig");
const packaging = @import("build/packaging.zig");
const gui = @import("build/gui.zig");
const tests = @import("build/tests.zig");
const cross = @import("build/cross.zig");
const diagram_renderer = @import("build/diagram_renderer.zig");
const syntax_highlighter = @import("build/syntax_highlighter.zig");
const headless = @import("build/headless.zig");

pub fn build(b: *std.Build) void {
    var app = Application.init(b) orelse return;
    app.modules.syntax_library = syntax_highlighter.add(b, app.modules);
    const bench = Benchmarks.init(b, app);
    experiments.add(b, app);
    const diagram_helper = diagram_renderer.add(b, app);
    packaging.add(b, app, diagram_helper);
    app.modules.gui = gui.add(b, app, diagram_helper);
    run_widget.addBuild(b, app);
    app.modules.headless = headless.add(b, app);
    const parallel_tests = tests.add(b, app, bench);
    parallel_tests.dependOn(cross.add(b));
}

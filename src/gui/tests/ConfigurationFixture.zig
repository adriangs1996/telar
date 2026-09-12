//! Real file watch and generation ownership around the native session fixture.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const Session = @import("Session.zig");
const Renderer = @import("../render/TerminalRenderer.zig");
const Fixture = @This();

session: *Session,
temp: std.testing.TmpDir,
path: []const u8,
trust_path: []const u8,

pub const viewport: @import("../native/native.zig").Viewport = .{ .width = 180, .height = 72, .scale = 1 };

pub fn init(source: []const u8, profile: ?[]const u8) !Fixture {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    errdefer temp.cleanup();
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temp.dir.realPath(io, &directory);
    const path = try std.fs.path.join(gpa, &.{ directory[0..length], "config.lua" });
    errdefer gpa.free(path);
    const trust_path = try std.fs.path.join(gpa, &.{ directory[0..length], "trust.json" });
    errdefer gpa.free(trust_path);
    const session = try Session.init();
    errdefer session.deinit();
    var fixture: Fixture = .{ .session = session, .temp = temp, .path = path, .trust_path = trust_path };
    try fixture.write("config.lua", source);
    session.gui.app.options.config_path = path;
    session.gui.app.options.trust_path = trust_path;
    session.gui.app.options.profile = profile;
    _ = try client.controllers.config_reloads.apply(&session.gui.app, try fixture.adoption());
    const generation = session.gui.app.lua_generation.?;
    const renderer = try Renderer.configured(gpa, io, .{ .config = generation.snapshot.gui, .theme = generation.snapshot.theme.terminal, .viewport = viewport });
    session.renderer.deinit();
    session.renderer = renderer;
    try session.gui.resize(try session.renderer.measure(viewport), renderer.theme);
    try session.bootstrap();
    session.gui.app.reload.mtime_ns = generation.watchFingerprint(io, path) ^
        @as(i128, session.gui.app.plugin_registry.?.watchFingerprint(gpa, io)) ^
        @as(i128, client.config_reload.trustWatchFingerprint(io, trust_path));
    session.driver.configuration.observe(renderer.config, viewport);
    try client.controllers.config_reloads.schedule(&session.gui.app);
    return fixture;
}

pub fn deinit(fixture: *Fixture) void {
    fixture.session.deinit();
    std.testing.allocator.free(fixture.path);
    std.testing.allocator.free(fixture.trust_path);
    fixture.temp.cleanup();
}

/// Models editors that replace a file atomically instead of writing in place.
/// Example: `try fixture.write("config.lua", source);`
pub fn write(fixture: *Fixture, name: []const u8, source: []const u8) !void {
    try fixture.temp.dir.writeFile(std.testing.io, .{ .sub_path = "save.tmp", .data = source });
    try fixture.temp.dir.rename("save.tmp", fixture.temp.dir, name, std.testing.io);
}

/// Waits for the actual worker with a deadline, leaving adoption to the test.
/// Example: `try fixture.wait();`
pub fn wait(fixture: *Fixture) !void {
    const reload = &fixture.session.driver.configuration;
    try reload.poll(&fixture.session.gui.app);
    for (0..1000) |_| {
        if (reload.ready.load(.acquire)) {
            try reload.poll(&fixture.session.gui.app);
            return;
        }

        try std.testing.io.sleep(.fromMilliseconds(10), .awake);
    }

    return error.ConfigWatchTimeout;
}

fn adoption(fixture: *Fixture) !client.ConfigAdoption {
    const gpa = std.testing.allocator;
    var diagnostic: client.Diagnostic = .{};
    const generation = try client.Generation.loadFile(.{ .gpa = gpa, .io = std.testing.io, .diagnostic = &diagnostic }, .{
        .path = fixture.path,
        .number = 1,
        .profile = fixture.session.gui.app.options.profile,
    });
    errdefer generation.deinit();
    const registry = try gpa.create(client.Registry);
    errdefer gpa.destroy(registry);
    registry.* = .{};
    const trust = try gpa.create(core.TrustStore);
    trust.* = .{};
    const snapshot = &generation.snapshot;
    return .{
        .generation = generation,
        .registry = registry,
        .trust_store = trust,
        .input = .{ .prefix = snapshot.prefix, .bindings = snapshot.bindingSlice(), .escape_timeout_ns = snapshot.input_escape_timeout_ns, .sequence_timeout_ns = snapshot.input_sequence_timeout_ns },
        .sidebar_rendering = .cells,
    };
}

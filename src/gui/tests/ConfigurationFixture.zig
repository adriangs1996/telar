//! Real file watch and generation ownership around the native session fixture.
const native = @import("../native/native.zig");
const data = @import("model");
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

pub const viewport: native.Viewport = .{ .width = 180, .height = 168, .scale = 1 };

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
    session.gui.app.options.profile = profile;
    const candidate = try fixture.adoption();
    session.gui.app.reload.next_generation = candidate.generation.number;
    _ = try client.config_adoption.completeConfigReload(
        session.gui.app,
        .{
            .loaded = .{
                .generation = candidate.generation,
                .registry = candidate.registry,
                .trust_store = candidate.trust_store,
                .mtime_ns = 0,
            },
        },
    );
    session.gui.app.options.config_path = path;
    session.gui.app.options.trust_path = trust_path;
    const generation = session.gui.app.lua_generation.?;
    const renderer = try Renderer.configured(gpa, io, .{ .config = generation.snapshot.gui, .theme = generation.snapshot.theme.terminal, .viewport = viewport });
    session.gui.renderer.deinit();
    session.gui.renderer = renderer;
    try session.gui.resize(try session.gui.renderer.measure(viewport), renderer.theme);
    try session.bootstrap();
    session.gui.app.reload.mtime_ns = generation.watchFingerprint(io, path) ^
        @as(i128, session.gui.app.plugin_registry.?.watchFingerprint(gpa, io)) ^
        @as(i128, client.config_reload.trustWatchFingerprint(io, trust_path));
    session.gui.driver.configuration.observe(renderer.config, viewport);
    try client.config_adoption.scheduleConfigReload(session.gui.app);
    try session.startJobs();
    return fixture;
}

pub fn deinit(self: *Fixture) void {
    self.session.deinit();
    std.testing.allocator.free(self.path);
    std.testing.allocator.free(self.trust_path);
    self.temp.cleanup();
}

/// Models editors that replace a file atomically instead of writing in place.
/// Example: `try fixture.write("config.lua", source);`
pub fn write(self: *Fixture, name: []const u8, source: []const u8) !void {
    try self.temp.dir.writeFile(std.testing.io, .{ .sub_path = "save.tmp", .data = source });
    try self.temp.dir.rename("save.tmp", self.temp.dir, name, std.testing.io);
}

/// Waits for the actual worker with a deadline, leaving adoption to the test.
/// Example: `try fixture.wait();`
pub fn wait(self: *Fixture) !void {
    const reload = &self.session.gui.driver.configuration;
    try self.session.startJobs();
    try reload.poll(self.session.gui.app);
    for (0..1000) |_| {
        if (reload.ready.load(.acquire)) {
            _ = try self.session.gui.update();
            if (!reload.ready.load(.acquire)) {
                return;
            }
        }

        try std.testing.io.sleep(.fromMilliseconds(10), .awake);
    }

    return error.ConfigWatchTimeout;
}

fn adoption(self: *Fixture) !client.ConfigAdoption {
    const gpa = std.testing.allocator;
    var diagnostic: data.Diagnostic = .{};
    const generation = try client.Generation.loadFile(.{ .gpa = gpa, .io = std.testing.io, .diagnostic = &diagnostic }, .{
        .path = self.path,
        .number = 1,
        .profile = self.session.gui.app.options.profile,
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
        .input = .{ .prefix = snapshot.prefix, .bindings = snapshot.bindingSlice(), .sequence_timeout_ns = snapshot.input_sequence_timeout_ns },
    };
}

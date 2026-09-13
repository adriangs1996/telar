const std = @import("std");
const Fixture = @import("ConfigurationFixture.zig");
const Session = @import("Session.zig");
const Quad = @import("../render/Quad.zig").Quad;

test "named theme reload changes chrome terminal colors and cursor without replacing the atlas" {
    const client = @import("telar-client");
    var fixture = try Fixture.init("return { api_version = 2, theme = 'vesper' }", null);
    defer fixture.deinit();
    const session = fixture.session;
    try session.receiveFrame(1);
    try present(session);
    const pixels = session.renderer.atlas.?.pixels.ptr;
    const version = session.renderer.atlas_version;
    const reload = &session.driver.configuration;
    try fixture.write("config.lua", "return { api_version = 2, theme = 'catppuccin' }");
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.renderer));
    try session.gui.resize(try session.renderer.measure(Fixture.viewport), session.renderer.theme);
    try present(session);
    try std.testing.expectEqualDeep(client.theme_support.builtin(.catppuccin), session.gui.theme);
    try std.testing.expectEqualDeep(session.gui.theme.terminal, session.renderer.theme);
    try std.testing.expectEqual(pixels, session.renderer.atlas.?.pixels.ptr);
    try std.testing.expectEqual(version, session.renderer.atlas_version);
    try std.testing.expectEqual(session.renderer.theme.palette, session.gui.app.model.hostCapabilities().terminal_colors.palette.?);

    try fixture.write("config.lua", "return { api_version = 2, theme = { base = 'catppuccin', terminal = { cursor_color = '#123456' } } }");
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.renderer));
    try present(session);
    try std.testing.expectEqual(@as(usize, 0), session.renderer.repainted_cells);
    try std.testing.expectEqual(version, session.renderer.atlas_version);

    session.gui.app.options.theme_locked = true;
    session.gui.app.options.theme = session.gui.theme;
    try fixture.write("config.lua", "return { api_version = 2, theme = 'tokyo-night', gui = { font = { size = 20 } } }");
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.renderer));
    try std.testing.expectEqualDeep(session.gui.app.options.theme.terminal, session.renderer.theme);
    try std.testing.expectEqualDeep(session.gui.app.options.theme, session.gui.theme);
    try std.testing.expectEqual(@as(f32, 20), session.renderer.config.font.size);
}

test "GUI reload preserves an in-flight frame and keeps input and receipt ACKs moving" {
    var fixture = try Fixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.driver.configuration;
    try session.receiveFrame(1);
    try session.settle();
    const token = try session.gui.prepare(&session.renderer);
    const quads = try std.testing.allocator.dupe(Quad, session.renderer.quads.items());
    defer std.testing.allocator.free(quads);
    const pixels = session.renderer.atlas.?.pixels.ptr;
    const version = session.renderer.atlas_version;
    try fixture.write("config.lua", "return { api_version = 2, gui = { font = { size = 20, line_height = 1.3, thicken = true } } }");
    try fixture.wait();
    try std.testing.expect(reload.prepared != null);
    try std.testing.expect(!try reload.apply(session.gui, &session.renderer));
    try std.testing.expectEqual(@as(u64, 1), session.gui.app.lua_generation.?.number);
    try std.testing.expectEqual(pixels, session.renderer.atlas.?.pixels.ptr);
    try std.testing.expectEqualSlices(Quad, quads, session.renderer.quads.items());
    try session.gui.input.accept(.{ .kind = 1, .text = "echo ready", .len = 10 });
    try session.gui.input.drain(&session.gui.app);
    try session.receiveFrame(2);
    try session.settle();
    try std.testing.expectEqualStrings("echo ready", session.input[0..session.input_len]);
    try std.testing.expectEqual(@as(usize, 2), session.ack_count);
    try session.gui.complete(token, true);
    try std.testing.expect(try reload.apply(session.gui, &session.renderer));
    try std.testing.expectEqual(@as(u64, 2), session.gui.app.lua_generation.?.number);
    try std.testing.expectEqual(@as(f32, 20), session.renderer.config.font.size);
    try std.testing.expectEqual(@import("builtin").os.tag == .macos, session.renderer.atlas.?.fonts.primary.mac_rasterizer != null);
    try std.testing.expect(pixels != session.renderer.atlas.?.pixels.ptr);
    try session.gui.resize(try session.renderer.measure(Fixture.viewport), session.renderer.theme);
    try present(session);
    try std.testing.expect(session.renderer.atlas_version > version);
    try std.testing.expectEqual(@as(usize, 2), session.ack_count);
}

test "GUI theme and cursor reload reuse glyph storage and publish terminal colors" {
    var fixture = try Fixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    const session = fixture.session;
    try session.receiveFrame(1);
    try present(session);
    const pixels = session.renderer.atlas.?.pixels.ptr;
    const shape_calls = session.renderer.atlas.?.shape_calls;
    const version = session.renderer.atlas_version;
    try fixture.write("config.lua",
        \\return { api_version = 2,
        \\  theme = { terminal = { foreground = "#123456", background = "#234567", cursor_color = "#fedcba" } },
        \\  gui = { cursor = { style = "bar", blink = false } }
        \\}
    );
    try fixture.wait();
    const reload = &session.driver.configuration;
    try std.testing.expect(reload.prepared == null);
    try std.testing.expect(try reload.apply(session.gui, &session.renderer));
    try session.gui.resize(try session.renderer.measure(Fixture.viewport), session.renderer.theme);
    try present(session);
    try std.testing.expectEqual(pixels, session.renderer.atlas.?.pixels.ptr);
    try std.testing.expectEqual(shape_calls, session.renderer.atlas.?.shape_calls);
    try std.testing.expectEqual(version, session.renderer.atlas_version);
    try std.testing.expectEqual(.bar, session.renderer.config.cursor.style);
    try std.testing.expect(!session.renderer.config.cursor.blink);
    try std.testing.expectEqual([3]u8{ 0x23, 0x45, 0x67 }, session.gui.app.model.hostCapabilities().terminal_colors.background);
    try std.testing.expectApproxEqAbs(@as(f32, 35.0 / 255.0), session.renderer.background.r, 0.001);
    const model_version = session.gui.app.model.version();
    try fixture.wait();
    try std.testing.expect(!reload.pending);
    // Native notification timers may advance while the unchanged-file worker
    // waits. The watch must preserve configuration, terminal state and resources.
    const after_wait = session.gui.app.model.version();
    try std.testing.expectEqual(model_version.configuration, after_wait.configuration);
    try std.testing.expectEqual(model_version.workspace, after_wait.workspace);
    try std.testing.expectEqual(model_version.frame, after_wait.frame);
    try std.testing.expectEqual(model_version.host, after_wait.host);
    try std.testing.expectEqual(pixels, session.renderer.atlas.?.pixels.ptr);
    try std.testing.expectEqual(version, session.renderer.atlas_version);
    try std.testing.expect(reload.worker != null);
}

test "GUI reload rejects Lua and native font failures without replacing the active generation" {
    var fixture = try Fixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.driver.configuration;
    const pixels = session.renderer.atlas.?.pixels.ptr;
    for ([_][]const u8{
        "return { api_version = 2, gui = {",
        "return { api_version = 2, gui = { font = { family = 'Telar-Test-Missing-Family-98a34b1' } } }",
    }) |source| {
        try fixture.write("config.lua", source);
        try fixture.wait();
        try std.testing.expect(!try reload.apply(session.gui, &session.renderer));
        try session.settle();
        try std.testing.expectEqual(@as(u64, 1), session.gui.app.lua_generation.?.number);
        try std.testing.expectEqual(@as(f32, 15), session.renderer.config.font.size);
        try std.testing.expectEqual(pixels, session.renderer.atlas.?.pixels.ptr);
        try std.testing.expect(session.gui.app.model.diagnostic() != null);
        try std.testing.expect(session.gui.app.reload.orphans.generation == null);
        try std.testing.expect(session.gui.app.reload.orphans.registry == null);
        try std.testing.expect(session.gui.app.reload.orphans.trust == null);
    }

    try fixture.write("config.lua", "return { api_version = 2, gui = { font = { size = 19 } } }");
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.renderer));
    try std.testing.expectEqual(@as(u64, 2), session.gui.app.lua_generation.?.number);
    try std.testing.expectEqual(@as(f32, 19), session.renderer.config.font.size);
    try std.testing.expect(session.gui.app.model.diagnostic() == null);
}

test "GUI reload restages fonts for a changed viewport before adopting and joins on close" {
    var fixture = try Fixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.driver.configuration;
    try fixture.write("config.lua", "return { api_version = 2, gui = { font = { size = 20 } } }");
    try fixture.wait();
    const viewport: @import("../native/native.zig").Viewport = .{ .width = 360, .height = 144, .scale = 2 };
    reload.observe(session.renderer.config, viewport);
    try std.testing.expect(!try reload.apply(session.gui, &session.renderer));
    try std.testing.expectEqual(@as(u64, 1), session.gui.app.lua_generation.?.number);
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.renderer));
    try std.testing.expectEqual(@as(u16, 40), session.renderer.atlas.?.pixel_height);
    try std.testing.expectEqual(@as(f32, 2), session.renderer.scale);
    try reload.poll(&session.gui.app);
    try std.testing.expect(reload.worker != null);
    // Deferred fixture teardown cancels this waiting worker before its borrows die.
}

test "GUI teardown releases a prepared font and unadopted Lua owners" {
    var fixture = try Fixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    try fixture.write("config.lua", "return { api_version = 2, gui = { font = { size = 21 } } }");
    try fixture.wait();
    try std.testing.expect(fixture.session.driver.configuration.prepared != null);
    try std.testing.expect(fixture.session.gui.app.reload.orphans.generation != null);
}

test "GUI native resources follow an adopted generation when downstream delivery fails" {
    var fixture = try Fixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.driver.configuration;
    try fixture.write("config.lua", "return { api_version = 2, client = { pane_gaps = false }, gui = { font = { size = 21 } } }");
    try fixture.wait();
    while (session.gui.app.runtime_transport.outbox.hasCapacity()) {
        try session.gui.app.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = Session.pane_id } });
    }

    try std.testing.expectError(error.ClientOutboxFull, reload.apply(session.gui, &session.renderer));
    try std.testing.expectEqual(@as(u64, 2), session.gui.app.model.configurationGeneration());
    try std.testing.expectEqual(@as(u64, 2), session.gui.app.lua_generation.?.number);
    try std.testing.expectEqual(@as(f32, 21), session.renderer.config.font.size);
    try std.testing.expectEqual(@as(u16, 21), session.renderer.atlas.?.pixel_height);
    try std.testing.expect(session.gui.app.reload.orphans.generation == null);
    try std.testing.expect(reload.prepared == null);
    try std.testing.expect(reload.retired != null);
}

test "GUI watches imported modules across atomic saves and retains the selected profile" {
    var fixture = try Fixture.init("return { api_version = 2, profiles = { large = { gui = { font = { size = 20 } } } } }", "large");
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.driver.configuration;
    try fixture.write("colors.lua", "return { background = '#123456' }");
    try fixture.write("config.lua",
        \\return { api_version = 2, theme = { terminal = require("colors") },
        \\  client = { sidebar = { renderer = "kitty-full" } },
        \\  profiles = { large = { gui = { font = { size = 20 } } } }
        \\}
    );
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.renderer));
    try fixture.write("colors.lua", "return { background = '#654321' }");
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.renderer));
    try std.testing.expectEqual(@as(u64, 3), session.gui.app.lua_generation.?.number);
    try std.testing.expectEqual(@as(f32, 20), session.renderer.config.font.size);
    try std.testing.expectEqual([3]u8{ 0x65, 0x43, 0x21 }, session.renderer.theme.background);
    try std.testing.expectEqual(.cells, session.gui.app.chrome.sidebarRenderer());
}

fn present(session: *Session) !void {
    const token = try session.gui.prepare(&session.renderer);
    try session.gui.complete(token, true);
    try session.settle();
}

test "font weight reload keeps PTY geometry and rebuilds only for effective macOS changes" {
    const is_macos = @import("builtin").os.tag == .macos;
    var fixture = try Fixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.driver.configuration;
    try session.receiveFrame(1);
    try present(session);
    const size = session.gui.app.model.hostSize();
    const resize_count = session.resize_count;
    for ([_][]const u8{
        "thicken_strength = 0",
        "thicken = true, thicken_strength = 0",
        "thicken = true, thicken_strength = 255",
        "thicken = false",
    }, 0..) |fields, index| {
        const pixels = session.renderer.atlas.?.pixels.ptr;
        var source: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&source, "return {{ api_version = 2, gui = {{ font = {{ {s} }} }} }}", .{fields});
        try fixture.write("config.lua", text);
        try fixture.wait();
        const rebuild = is_macos and index != 0;
        try std.testing.expectEqual(rebuild, reload.prepared != null);
        try std.testing.expect(try reload.apply(session.gui, &session.renderer));
        try std.testing.expectEqual(rebuild, pixels != session.renderer.atlas.?.pixels.ptr);
        const measured = try session.renderer.measure(Fixture.viewport);
        try std.testing.expectEqual(size, measured);
        try session.gui.resize(measured, session.renderer.theme);
        try present(session);
        try std.testing.expectEqual(resize_count, session.resize_count);
    }
}

test "window reload reuses the atlas and padding publishes grid size without its border pixels" {
    var fixture = try Fixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.driver.configuration;
    try session.receiveFrame(1);
    try present(session);
    const pixels = session.renderer.atlas.?.pixels.ptr;
    const version = session.renderer.atlas_version;
    const previous_size = session.gui.app.model.hostSize();
    try fixture.write("config.lua", "return { api_version = 2, gui = { window = { background_opacity = 0.45, background_blur = true, titlebar = false } } }");
    try fixture.wait();
    try std.testing.expect(reload.prepared == null);
    try std.testing.expect(try reload.apply(session.gui, &session.renderer));
    try present(session);
    try std.testing.expectEqual(@as(usize, 0), session.renderer.repainted_cells);
    try std.testing.expectEqual(@as(f32, 0.45), session.renderer.frame(1).background[3]);
    try std.testing.expectEqual(@as(u32, 20), session.renderer.frame(1).background_blur);
    try std.testing.expectEqual(@as(u32, 0), session.renderer.frame(1).titlebar);

    try fixture.write("config.lua", "return { api_version = 2, gui = { window = { padding = { x = 12, y = 18 } } } }");
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.renderer));
    const size = try session.renderer.measure(Fixture.viewport);
    try session.gui.resize(size, session.renderer.theme);
    try present(session);
    try std.testing.expect(size.cols < previous_size.cols and size.rows < previous_size.rows);
    try std.testing.expectEqual(size, session.gui.app.model.hostSize());
    const pane_origin = session.gui.region.area;
    const pixels_origin = session.renderer.metrics.rect(session.renderer.origin, pane_origin);
    const retained = session.renderer.retained.at(.{ pane_origin.x, pane_origin.y });
    try std.testing.expectEqual(pixels_origin.x, retained.paint.rect.x);
    try std.testing.expectEqual(pixels_origin.y, retained.paint.rect.y);
    try std.testing.expectEqual([2]u32{ 12, 18 }, session.renderer.origin);
    try std.testing.expectEqual(pixels, session.renderer.atlas.?.pixels.ptr);
    try std.testing.expectEqual(version, session.renderer.atlas_version);
    try std.testing.expect(session.resize_count > 0);
    try std.testing.expectEqual(@as(f32, 1), session.renderer.frame(1).background[3]);
    try std.testing.expectEqual(@as(u32, 0), session.renderer.frame(1).background_blur);
}

test "blur radius and titlebar reload preserve the atlas and geometry through validation failure" {
    var fixture = try Fixture.init("return { api_version = 2, gui = { window = { background_opacity = 0.5 } } }", null);
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.driver.configuration;
    try session.receiveFrame(1);
    try present(session);
    const pixels = session.renderer.atlas.?.pixels.ptr;
    const version = session.renderer.atlas_version;
    const shape_calls = session.renderer.atlas.?.shape_calls;
    const size = session.gui.app.model.hostSize();
    const resizes = session.resize_count;
    for ([_]u8{ 1, 40, 255, 0 }, [_]bool{ false, true, false, true }) |radius, titlebar| {
        var source: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&source, "return {{ api_version = 2, gui = {{ window = {{ background_opacity = 0.5, background_blur = {d}, titlebar = {} }} }} }}", .{ radius, titlebar });
        try fixture.write("config.lua", text);
        try fixture.wait();
        try std.testing.expect(reload.prepared == null);
        try std.testing.expect(try reload.apply(session.gui, &session.renderer));
        try present(session);
        try std.testing.expectEqual(@as(u32, radius), session.renderer.frame(1).background_blur);
        try std.testing.expectEqual(@as(u32, @intFromBool(titlebar)), session.renderer.frame(1).titlebar);
        try std.testing.expectEqual(size, try session.renderer.measure(Fixture.viewport));
        try std.testing.expectEqual(resizes, session.resize_count);
        try std.testing.expectEqual(pixels, session.renderer.atlas.?.pixels.ptr);
        try std.testing.expectEqual(version, session.renderer.atlas_version);
        try std.testing.expectEqual(shape_calls, session.renderer.atlas.?.shape_calls);
        try std.testing.expectEqual(@as(usize, 0), session.renderer.repainted_cells);
    }

    const generation = session.gui.app.lua_generation.?.number;
    try fixture.write("config.lua", "return { api_version = 2, gui = { window = { background_blur = 256, titlebar = false } } }");
    try fixture.wait();
    try std.testing.expect(!try reload.apply(session.gui, &session.renderer));
    try std.testing.expectEqual(generation, session.gui.app.lua_generation.?.number);
    try std.testing.expectEqual(@as(u32, 0), session.renderer.frame(1).background_blur);
    try std.testing.expectEqual(@as(u32, 1), session.renderer.frame(1).titlebar);
    try std.testing.expectEqual(pixels, session.renderer.atlas.?.pixels.ptr);
}

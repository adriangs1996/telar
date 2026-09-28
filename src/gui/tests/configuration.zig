const data = @import("model");
const builtin = @import("builtin");
const native = @import("../native/native.zig");
const input_support = @import("input_support.zig");
const std = @import("std");
const Fixture = @import("ConfigurationFixture.zig");
const Session = @import("Session.zig");
const client = @import("telar-client");
const gfx = @import("gfx");
const Quad = gfx.Quad.Quad;

test "named theme reload changes chrome terminal colors and cursor without replacing the atlas" {
    var fixture = try Fixture.init("return { api_version = 2, theme = 'vesper' }", null);
    defer fixture.deinit();
    const session = fixture.session;
    try session.receiveFrame(1);
    try present(session);
    const pixels = session.gui.renderer.atlas.?.pixels.ptr;
    const version = session.gui.renderer.atlas_version;
    const reload = &session.gui.driver.configuration;
    try fixture.write("config.lua", "return { api_version = 2, theme = 'catppuccin' }");
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.gui.renderer));
    try session.gui.resize(try session.gui.renderer.measure(Fixture.viewport), session.gui.renderer.theme);
    try present(session);
    try std.testing.expectEqualDeep(data.theme_support.builtin(.catppuccin), session.gui.app.model.theme);
    try std.testing.expectEqualDeep(session.gui.app.model.theme.terminal, session.gui.renderer.theme);
    try std.testing.expectEqual(pixels, session.gui.renderer.atlas.?.pixels.ptr);
    try std.testing.expectEqual(version, session.gui.renderer.atlas_version);
    try std.testing.expectEqual(session.gui.renderer.theme.palette, session.gui.app.model.host.host_capabilities.terminal_colors.palette.?);

    try fixture.write("config.lua", "return { api_version = 2, theme = { base = 'catppuccin', terminal = { cursor_color = '#123456' } } }");
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.gui.renderer));
    try present(session);
    try std.testing.expectEqual(@as(usize, 0), session.gui.renderer.repainted_cells);
    try std.testing.expectEqual(version, session.gui.renderer.atlas_version);

    session.gui.app.options.theme_locked = true;
    session.gui.app.options.theme = session.gui.app.model.theme;
    try fixture.write("config.lua", "return { api_version = 2, theme = 'tokyo-night', gui = { font = { size = 20 } } }");
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.gui.renderer));
    try std.testing.expectEqualDeep(session.gui.app.options.theme.terminal, session.gui.renderer.theme);
    try std.testing.expectEqualDeep(session.gui.app.options.theme, session.gui.app.model.theme);
    try std.testing.expectEqual(@as(f32, 20), session.gui.renderer.config.font.size);
}

test "GUI reload preserves an in-flight frame and keeps input and receipt ACKs moving" {
    var fixture = try Fixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.gui.driver.configuration;
    try session.receiveFrame(1);
    try session.settle();
    const token = try session.draw();
    const quads = try std.testing.allocator.dupe(Quad, session.gui.renderer.quads.items());
    defer std.testing.allocator.free(quads);
    const pixels = session.gui.renderer.atlas.?.pixels.ptr;
    const version = session.gui.renderer.atlas_version;
    try fixture.write("config.lua", "return { api_version = 2, gui = { font = { size = 20, line_height = 1.3, thicken = true } } }");
    try fixture.wait();
    try std.testing.expect(reload.prepared != null);
    try std.testing.expect(!try reload.apply(session.gui, &session.gui.renderer));
    try std.testing.expectEqual(@as(u64, 1), session.gui.app.lua_generation.?.number);
    try std.testing.expectEqual(pixels, session.gui.renderer.atlas.?.pixels.ptr);
    try std.testing.expectEqualSlices(
        Quad,
        quads,
        session.gui.renderer.quads.items(),
    );
    try input_support.acceptNative(session.gui, .{ .kind = 1, .text = "echo ready", .len = 10 });
    try input_support.pump(session.gui);
    try session.receiveFrame(2);
    try session.settle();
    try std.testing.expectEqualStrings("echo ready", session.input[0..session.input_len]);
    try std.testing.expectEqual(@as(usize, 2), session.ack_count);
    try input_support.presented(
        session.gui,
        token,
        true,
    );
    try std.testing.expect(try reload.apply(session.gui, &session.gui.renderer));
    try std.testing.expectEqual(@as(u64, 2), session.gui.app.lua_generation.?.number);
    try std.testing.expectEqual(@as(f32, 20), session.gui.renderer.config.font.size);
    try std.testing.expectEqual(builtin.os.tag == .macos, session.gui.renderer.atlas.?.fonts.primary.mac_rasterizer != null);
    try std.testing.expect(pixels != session.gui.renderer.atlas.?.pixels.ptr);
    try session.gui.resize(try session.gui.renderer.measure(Fixture.viewport), session.gui.renderer.theme);
    try present(session);
    try std.testing.expect(session.gui.renderer.atlas_version > version);
    try std.testing.expectEqual(@as(usize, 2), session.ack_count);
}

test "GUI theme and cursor reload reuse glyph storage and publish terminal colors" {
    var fixture = try Fixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    const session = fixture.session;
    try session.receiveFrame(1);
    try present(session);
    const pixels = session.gui.renderer.atlas.?.pixels.ptr;
    const shape_calls = session.gui.renderer.atlas.?.shape_calls;
    const version = session.gui.renderer.atlas_version;
    try fixture.write("config.lua",
        \\return { api_version = 2,
        \\  theme = { terminal = { foreground = "#123456", background = "#234567", cursor_color = "#fedcba" } },
        \\  gui = { cursor = { style = "bar", blink = false } }
        \\}
    );
    try fixture.wait();
    const reload = &session.gui.driver.configuration;
    try std.testing.expect(reload.prepared == null);
    try std.testing.expect(try reload.apply(session.gui, &session.gui.renderer));
    try session.gui.resize(try session.gui.renderer.measure(Fixture.viewport), session.gui.renderer.theme);
    try present(session);
    try std.testing.expectEqual(pixels, session.gui.renderer.atlas.?.pixels.ptr);
    try std.testing.expectEqual(shape_calls, session.gui.renderer.atlas.?.shape_calls);
    try std.testing.expectEqual(version, session.gui.renderer.atlas_version);
    try std.testing.expectEqual(.bar, session.gui.renderer.config.cursor.style);
    try std.testing.expect(!session.gui.renderer.config.cursor.blink);
    try std.testing.expectEqual([3]u8{ 0x23, 0x45, 0x67 }, session.gui.app.model.host.host_capabilities.terminal_colors.background);
    try std.testing.expectApproxEqAbs(
        @as(f32, 35.0 / 255.0),
        session.gui.renderer.background.r,
        0.001,
    );
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
    try std.testing.expectEqual(pixels, session.gui.renderer.atlas.?.pixels.ptr);
    try std.testing.expectEqual(version, session.gui.renderer.atlas_version);
    try std.testing.expect(reload.worker != null);
}

test "GUI reload rejects Lua and native font failures without replacing the active generation" {
    var fixture = try Fixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.gui.driver.configuration;
    const pixels = session.gui.renderer.atlas.?.pixels.ptr;
    for ([_][]const u8{
        "return { api_version = 2, gui = {",
        "return { api_version = 2, gui = { font = { family = 'Telar-Test-Missing-Family-98a34b1' } } }",
    }) |source| {
        try fixture.write("config.lua", source);
        try fixture.wait();
        try std.testing.expect(!try reload.apply(session.gui, &session.gui.renderer));
        try session.settle();
        try std.testing.expectEqual(@as(u64, 1), session.gui.app.lua_generation.?.number);
        try std.testing.expectEqual(@as(f32, 15), session.gui.renderer.config.font.size);
        try std.testing.expectEqual(pixels, session.gui.renderer.atlas.?.pixels.ptr);
        try std.testing.expect(data.client_diagnostic.shown(&session.gui.app.model) != null);
        try std.testing.expect(session.gui.app.reload.orphans.generation == null);
        try std.testing.expect(session.gui.app.reload.orphans.registry == null);
        try std.testing.expect(session.gui.app.reload.orphans.trust == null);
    }

    try fixture.write("config.lua", "return { api_version = 2, gui = { font = { size = 19 } } }");
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.gui.renderer));
    try std.testing.expectEqual(@as(u64, 2), session.gui.app.lua_generation.?.number);
    try std.testing.expectEqual(@as(f32, 19), session.gui.renderer.config.font.size);
    try std.testing.expect(data.client_diagnostic.shown(&session.gui.app.model) == null);
}

test "GUI reload restages fonts for a changed viewport before adopting and joins on close" {
    var fixture = try Fixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.gui.driver.configuration;
    try fixture.write("config.lua", "return { api_version = 2, gui = { font = { size = 20 } } }");
    try fixture.wait();
    const viewport: native.Viewport = .{ .width = 360, .height = 144, .scale = 2 };
    reload.observe(session.gui.renderer.config, viewport);
    try std.testing.expect(!try reload.apply(session.gui, &session.gui.renderer));
    try std.testing.expectEqual(@as(u64, 1), session.gui.app.lua_generation.?.number);
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.gui.renderer));
    try std.testing.expectEqual(@as(u16, 40), session.gui.renderer.atlas.?.pixel_height);
    try std.testing.expectEqual(@as(f32, 2), session.gui.renderer.scale);
    try session.startJobs();
    try reload.poll(session.gui.app);
    try std.testing.expect(reload.worker != null);
    // Deferred fixture teardown cancels this waiting worker before its borrows die.
}

test "GUI teardown releases a prepared font and unadopted Lua owners" {
    var fixture = try Fixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    try fixture.write("config.lua", "return { api_version = 2, gui = { font = { size = 21 } } }");
    try fixture.wait();
    try std.testing.expect(fixture.session.gui.driver.configuration.prepared != null);
    try std.testing.expect(fixture.session.gui.app.reload.orphans.generation != null);
}

test "GUI native resources follow an adopted generation when downstream delivery fails" {
    var fixture = try Fixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.gui.driver.configuration;
    try fixture.write("config.lua", "return { api_version = 2, client = { pane_gaps = false }, gui = { font = { size = 21 } } }");
    try fixture.wait();
    while (session.gui.app.model.to_runtime.hasCapacity()) {
        try session.gui.app.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = Session.pane_id } });
    }

    try std.testing.expectError(error.ClientOutboxFull, reload.apply(session.gui, &session.gui.renderer));
    try std.testing.expectEqual(@as(u64, 2), session.gui.app.model.configuration_generation);
    try std.testing.expectEqual(@as(u64, 2), session.gui.app.lua_generation.?.number);
    try std.testing.expectEqual(@as(f32, 21), session.gui.renderer.config.font.size);
    try std.testing.expectEqual(@as(u16, 21), session.gui.renderer.atlas.?.pixel_height);
    try std.testing.expect(session.gui.app.reload.orphans.generation == null);
    try std.testing.expect(reload.prepared == null);
    try std.testing.expect(reload.retired != null);
}

test "GUI watches imported modules across atomic saves and retains the selected profile" {
    var fixture = try Fixture.init("return { api_version = 2, profiles = { large = { gui = { font = { size = 20 } } } } }", "large");
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.gui.driver.configuration;
    try fixture.write("colors.lua", "return { background = '#123456' }");
    try fixture.write("config.lua",
        \\return { api_version = 2, theme = { terminal = require("colors") },
        \\  client = { sidebar = { renderer = "kitty-full" } },
        \\  profiles = { large = { gui = { font = { size = 20 } } } }
        \\}
    );
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.gui.renderer));
    try fixture.write("colors.lua", "return { background = '#654321' }");
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.gui.renderer));
    try std.testing.expectEqual(@as(u64, 3), session.gui.app.lua_generation.?.number);
    try std.testing.expectEqual(@as(f32, 20), session.gui.renderer.config.font.size);
    try std.testing.expectEqual(
        [3]u8{
            0x65,
            0x43,
            0x21,
        },
        session.gui.renderer.theme.background,
    );
}

test "chrome scale reload enlarges chrome text without resizing the PTY or the atlas" {
    var fixture = try Fixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.gui.driver.configuration;
    try session.receiveFrame(1);
    try present(session);
    const size = session.gui.app.model.host.host_size;
    const resize_count = session.resize_count;
    const pixels = session.gui.renderer.atlas.?.pixels.ptr;
    const before = session.gui.renderer.chrome;
    try fixture.write("config.lua", "return { api_version = 2, gui = { chrome = { scale = 1.5 } } }");
    try fixture.wait();
    try std.testing.expect(reload.prepared == null);
    try std.testing.expect(try reload.apply(session.gui, &session.gui.renderer));
    try std.testing.expectEqual(@as(f32, 1.5), session.gui.renderer.config.chrome.scale);
    const measured = try session.gui.renderer.measure(Fixture.viewport);
    try std.testing.expectEqual(size, measured);
    try session.gui.resize(measured, session.gui.renderer.theme);
    try present(session);
    try std.testing.expectEqual(resize_count, session.resize_count);
    try std.testing.expectEqual(pixels, session.gui.renderer.atlas.?.pixels.ptr);
    try std.testing.expectEqual(before.vertical(), session.gui.renderer.chrome.vertical());
    try std.testing.expect(session.gui.renderer.chrome.title > before.title);
    try std.testing.expect(session.gui.renderer.chrome.small > before.small);
}

fn present(session: *Session) !void {
    const token = try session.draw();
    try input_support.presented(
        session.gui,
        token,
        true,
    );
    try session.settle();
}

test "font weight reload keeps PTY geometry and rebuilds only for effective macOS changes" {
    const is_macos = builtin.os.tag == .macos;
    var fixture = try Fixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.gui.driver.configuration;
    try session.receiveFrame(1);
    try present(session);
    const size = session.gui.app.model.host.host_size;
    const resize_count = session.resize_count;
    for ([_][]const u8{
        "thicken_strength = 0",
        "thicken = true, thicken_strength = 0",
        "thicken = true, thicken_strength = 255",
        "thicken = false",
    }, 0..) |fields, index| {
        const pixels = session.gui.renderer.atlas.?.pixels.ptr;
        var source: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&source, "return {{ api_version = 2, gui = {{ font = {{ {s} }} }} }}", .{fields});
        try fixture.write("config.lua", text);
        try fixture.wait();
        const rebuild = is_macos and index != 0;
        try std.testing.expectEqual(rebuild, reload.prepared != null);
        try std.testing.expect(try reload.apply(session.gui, &session.gui.renderer));
        try std.testing.expectEqual(rebuild, pixels != session.gui.renderer.atlas.?.pixels.ptr);
        const measured = try session.gui.renderer.measure(Fixture.viewport);
        try std.testing.expectEqual(size, measured);
        try session.gui.resize(measured, session.gui.renderer.theme);
        try present(session);
        try std.testing.expectEqual(resize_count, session.resize_count);
    }
}

test "window reload reuses the atlas and padding publishes grid size without its border pixels" {
    var fixture = try Fixture.init("return { api_version = 2 }", null);
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.gui.driver.configuration;
    try session.receiveFrame(1);
    try present(session);
    const pixels = session.gui.renderer.atlas.?.pixels.ptr;
    const version = session.gui.renderer.atlas_version;
    const previous_size = session.gui.app.model.host.host_size;
    try fixture.write("config.lua", "return { api_version = 2, gui = { window = { background_opacity = 0.45, background_blur = true, titlebar = false } } }");
    try fixture.wait();
    try std.testing.expect(reload.prepared == null);
    try std.testing.expect(try reload.apply(session.gui, &session.gui.renderer));
    try present(session);
    try std.testing.expectEqual(@as(usize, 0), session.gui.renderer.repainted_cells);
    try std.testing.expectEqual(@as(f32, 0.45), session.gui.renderer.frame(1).background[3]);
    try std.testing.expectEqual(@as(u32, 20), session.gui.renderer.frame(1).background_blur);
    try std.testing.expectEqual(@as(u32, 0), session.gui.renderer.frame(1).titlebar);

    try fixture.write("config.lua", "return { api_version = 2, gui = { window = { padding = { x = 12, y = 18 } } } }");
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.gui.renderer));
    const size = try session.gui.renderer.measure(Fixture.viewport);
    try session.gui.resize(size, session.gui.renderer.theme);
    try present(session);
    try std.testing.expect(size.cols < previous_size.cols and size.rows < previous_size.rows);
    try std.testing.expectEqual(size, session.gui.app.model.host.host_size);
    const pane_origin = data.workbench.region(&session.gui.app.model).area;
    const pixels_origin = session.gui.renderer.metrics.rect(session.gui.renderer.origin, pane_origin);
    const retained = session.gui.renderer.retained.at(
        .{
            pane_origin.x,
            pane_origin.y,
        },
    );
    try std.testing.expectEqual(pixels_origin.x, retained.metadata.paint.rect.x);
    try std.testing.expectEqual(pixels_origin.y, retained.metadata.paint.rect.y);
    const chrome = session.gui.renderer.chrome;
    try std.testing.expectEqual(
        [2]u32{
            12,
            chrome.top_bar + 18,
        },
        session.gui.renderer.origin,
    );
    try std.testing.expectEqual(pixels, session.gui.renderer.atlas.?.pixels.ptr);
    try std.testing.expectEqual(version, session.gui.renderer.atlas_version);
    try std.testing.expect(session.resize_count > 0);
    try std.testing.expectEqual(@as(f32, 1), session.gui.renderer.frame(1).background[3]);
    try std.testing.expectEqual(@as(u32, 0), session.gui.renderer.frame(1).background_blur);
}

test "blur radius and titlebar reload preserve the atlas and geometry through validation failure" {
    var fixture = try Fixture.init("return { api_version = 2, gui = { window = { background_opacity = 0.5 } } }", null);
    defer fixture.deinit();
    const session = fixture.session;
    const reload = &session.gui.driver.configuration;
    try session.receiveFrame(1);
    try present(session);
    const pixels = session.gui.renderer.atlas.?.pixels.ptr;
    const version = session.gui.renderer.atlas_version;
    const shape_calls = session.gui.renderer.atlas.?.shape_calls;
    const size = session.gui.app.model.host.host_size;
    const resizes = session.resize_count;
    for ([_]u8{ 1, 40, 255, 0 }, [_]bool{ false, true, false, true }) |radius, titlebar| {
        var source: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&source, "return {{ api_version = 2, gui = {{ window = {{ background_opacity = 0.5, background_blur = {d}, titlebar = {} }} }} }}", .{ radius, titlebar });
        try fixture.write("config.lua", text);
        try fixture.wait();
        try std.testing.expect(reload.prepared == null);
        try std.testing.expect(try reload.apply(session.gui, &session.gui.renderer));
        try present(session);
        try std.testing.expectEqual(@as(u32, radius), session.gui.renderer.frame(1).background_blur);
        try std.testing.expectEqual(@as(u32, @intFromBool(titlebar)), session.gui.renderer.frame(1).titlebar);
        try std.testing.expectEqual(size, try session.gui.renderer.measure(Fixture.viewport));
        try std.testing.expectEqual(resizes, session.resize_count);
        try std.testing.expectEqual(pixels, session.gui.renderer.atlas.?.pixels.ptr);
        try std.testing.expectEqual(version, session.gui.renderer.atlas_version);
        try std.testing.expectEqual(shape_calls, session.gui.renderer.atlas.?.shape_calls);
        try std.testing.expectEqual(@as(usize, 0), session.gui.renderer.repainted_cells);
    }

    const generation = session.gui.app.lua_generation.?.number;
    try fixture.write("config.lua", "return { api_version = 2, gui = { window = { background_blur = 256, titlebar = false } } }");
    try fixture.wait();
    try std.testing.expect(!try reload.apply(session.gui, &session.gui.renderer));
    try std.testing.expectEqual(generation, session.gui.app.lua_generation.?.number);
    try std.testing.expectEqual(@as(u32, 0), session.gui.renderer.frame(1).background_blur);
    try std.testing.expectEqual(@as(u32, 1), session.gui.renderer.frame(1).titlebar);
    try std.testing.expectEqual(pixels, session.gui.renderer.atlas.?.pixels.ptr);
}

test "editor reload overrides EDITOR and removal restores the startup fallback" {
    var fixture = try Fixture.init("return { api_version = 2, client = { editor = '/opt/nvim' } }", null);
    defer fixture.deinit();
    const session = fixture.session;
    const app = session.gui.app;
    const reload = &session.gui.driver.configuration;
    app.options.editor = "vi";
    try std.testing.expectEqualStrings("/opt/nvim", client.editor_file_links.editorExecutable(app));

    try fixture.write("config.lua", "return { api_version = 2, client = { editor = '/opt/other editor' } }");
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.gui.renderer));
    try std.testing.expectEqualStrings("/opt/other editor", client.editor_file_links.editorExecutable(app));

    try fixture.write("config.lua", "return { api_version = 2, client = { editor = false } }");
    try fixture.wait();
    _ = try reload.apply(session.gui, &session.gui.renderer);
    try std.testing.expectEqualStrings("/opt/other editor", client.editor_file_links.editorExecutable(app));

    try fixture.write("config.lua", "return { api_version = 2 }");
    try fixture.wait();
    try std.testing.expect(try reload.apply(session.gui, &session.gui.renderer));
    try std.testing.expectEqualStrings("vi", client.editor_file_links.editorExecutable(app));
}

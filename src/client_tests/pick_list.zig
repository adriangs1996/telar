//! Client integration tests for pick lists: options written in the
//! configuration or printed by a command, commands that fail, hang or print
//! too much, and `on_select` receiving the choice as one argument before the
//! bar reruns.
const client_module = @import("telar-client");
const data = @import("model");
const ClientHarness = @import("ClientHarness.zig");
const std = @import("std");
const fixtures = @import("fixtures.zig");

test "written options open ready and the choice reaches on_select as one argument" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try absolutePath(&temp, &directory_buffer);
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;

    const hostile = "x; touch pwned $(touch pwned2)";
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\local telar = require("telar")
        \\return {{ api_version = 2, client = {{
        \\  picks = {{
        \\    level = telar.pick({{
        \\      title = "Thinking level",
        \\      items = {{ "low", {{ label = "hostile", value = "{s}", detail = "quoted" }} }},
        \\      on_select = {{ "/bin/sh", "-c", 'cd "$0" && printf %s "$1" > choice', "{s}", "{{}}" }},
        \\    }}),
        \\  }},
        \\  bars = {{ bottom = {{
        \\    left = telar.bar.command({{
        \\      command = {{ "/bin/sh", "-c", 'cat "$0/choice" 2>/dev/null || printf none', "{s}" }},
        \\      every_ms = 3600000,
        \\    }}),
        \\    right = telar.bar.tabs(),
        \\  }} }},
        \\}} }}
    , .{ hostile, directory, directory });
    defer std.testing.allocator.free(source);
    _ = try fixtures.reloadConfiguration(&harness, try fixtures.testingConfigAdoptionSource(1, source));
    try settleBar(&harness, "none");

    _ = try client_module.actions.executeAction(client, .{ .pick = 0 }, .binding);
    const prompt = client.model.name_prompt.currentConst().?;
    try std.testing.expect(prompt.target() == .pick);
    try std.testing.expectEqual(data.PickListState.Phase.ready, client.model.pick_list.phase);
    try std.testing.expectEqualStrings("Thinking level", client.model.pick_list.title());
    try std.testing.expectEqual(@as(u16, 2), client.model.pick_list.items.count);
    try std.testing.expectEqualStrings("quoted", client.model.pick_list.items.detail(1));

    try typeText(client, "hosti");
    try pressEnter(client);
    try std.testing.expect(!client.model.name_prompt.active());
    try std.testing.expectEqual(data.PickListState.Phase.closed, client.model.pick_list.phase);
    try std.testing.expect(client.model.pick_list.selecting != .none);

    const finished = try receivePick(&harness);
    try std.testing.expectEqual(client_module.PickCommandJob.Purpose.select, finished.purpose);
    try client_module.pick_list.finish(client, finished);
    try std.testing.expect(client.model.pick_list.selecting == .none);
    try std.testing.expect(data.client_diagnostic.shown(&client.model) == null);

    var written: [128]u8 = undefined;
    const choice = try temp.dir.readFile(std.testing.io, "choice", &written);
    try std.testing.expectEqualStrings(hostile, choice);
    try std.testing.expectError(error.FileNotFound, temp.dir.access(std.testing.io, "pwned", .{}));
    try std.testing.expectError(error.FileNotFound, temp.dir.access(std.testing.io, "pwned2", .{}));

    // The bar source runs again at once instead of in an hour.
    try settleBar(&harness, hostile);
}

test "a command lists one option per line or through its items function" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try fixtures.reloadConfiguration(&harness, try fixtures.testingConfigAdoptionSource(1,
        \\local telar = require("telar")
        \\return { api_version = 2, client = { picks = {
        \\  lines = telar.pick({
        \\    command = { "/bin/sh", "-c", "printf 'alpha\n\n  beta  \ngamma\n'" },
        \\    on_select = { "/bin/sh", "-c", ":", "{}" },
        \\  }),
        \\  models = telar.pick({
        \\    command = { "/bin/sh", "-c", "printf 'provider model\nanthropic opus\nopenai gpt\n'" },
        \\    items = function(ctx)
        \\      local options = {}
        \\      for provider, model in ctx.output:gmatch("\n(%S+)%s+(%S+)") do
        \\        options[#options + 1] = { label = model, detail = provider, value = provider .. "/" .. model }
        \\      end
        \\      return options
        \\    end,
        \\    on_select = { "/bin/sh", "-c", ":", "{}" },
        \\  }),
        \\} } }
    ));

    // Names sort, so `lines` is 0 and `models` is 1.
    _ = try client_module.actions.executeAction(client, .{ .pick = 0 }, .binding);
    try std.testing.expectEqual(data.PickListState.Phase.loading, client.model.pick_list.phase);
    try pressEnter(client);
    try std.testing.expect(client.model.name_prompt.active());

    try client_module.pick_list.finish(client, try receivePick(&harness));
    const items = &client.model.pick_list.items;
    try std.testing.expectEqual(data.PickListState.Phase.ready, client.model.pick_list.phase);
    try std.testing.expectEqual(@as(u16, 3), items.count);
    try std.testing.expectEqualStrings("beta", items.label(1));

    _ = try client_module.name_prompt.inputPrompt(client, .{ .key = .{ .code = .escape } });
    try std.testing.expectEqual(data.PickListState.Phase.closed, client.model.pick_list.phase);

    _ = try client_module.actions.executeAction(client, .{ .pick = 1 }, .binding);
    try client_module.pick_list.finish(client, try receivePick(&harness));
    try std.testing.expectEqual(@as(u16, 2), items.count);
    try std.testing.expectEqualStrings("gpt", items.label(1));
    try std.testing.expectEqualStrings("openai", items.detail(1));
    try std.testing.expectEqualStrings("openai/gpt", items.value(1));
}

test "a failing or slow list command keeps the palette open with the reason" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try fixtures.reloadConfiguration(&harness, try fixtures.testingConfigAdoptionSource(1,
        \\local telar = require("telar")
        \\local done = { "/bin/sh", "-c", ":", "{}" }
        \\return { api_version = 2, client = { picks = {
        \\  a_failing = telar.pick({ command = { "/bin/sh", "-c", "exit 3" }, on_select = done }),
        \\  b_slow = telar.pick({ command = { "/bin/sh", "-c", "sleep 5" }, timeout_ms = 100, on_select = done }),
        \\  c_control = telar.pick({ command = { "/bin/sh", "-c", "printf 'a\\033b'" }, on_select = done }),
        \\} } }
    ));

    const expected = [_][]const u8{
        "the list command exited with an error",
        "the list command timed out",
        "the list command printed control characters or invalid UTF-8",
    };
    for (expected, 0..) |reason, index| {
        _ = try client_module.actions.executeAction(client, .{ .pick = @intCast(index) }, .binding);
        try client_module.pick_list.finish(client, try receivePick(&harness));
        try std.testing.expectEqual(data.PickListState.Phase.failed, client.model.pick_list.phase);
        try std.testing.expectEqualStrings(reason, client.model.pick_list.errorSlice());
        try std.testing.expectEqual(@as(u16, 0), client.model.pick_list.items.count);

        try pressEnter(client);
        try std.testing.expect(client.model.name_prompt.active());
        _ = try client_module.name_prompt.inputPrompt(client, .{ .key = .{ .code = .escape } });
    }
}

test "a list command past a limit shows the options that fit and reports the limit" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try fixtures.reloadConfiguration(&harness, try fixtures.testingConfigAdoptionSource(1,
        \\local telar = require("telar")
        \\local done = { "/bin/sh", "-c", ":", "{}" }
        \\return { api_version = 2, client = { picks = {
        \\  a_long = telar.pick({ command = { "/bin/sh", "-c", "seq 1 5000" }, on_select = done }),
        \\  b_wide = telar.pick({ command = { "/bin/sh", "-c", "seq 1 3; head -c 300000 /dev/zero | tr '\\0' x" }, on_select = done }),
        \\  c_line = telar.pick({ command = { "/bin/sh", "-c", "head -c 600 /dev/zero | tr '\\0' x; echo; echo short" }, on_select = done }),
        \\} } }
    ));

    const cases = [_]struct { []const u8, u16 }{
        .{ "picks.max_items", data.PickItems.max_items },
        .{ "picks.max_pick_output_bytes", 3 },
        .{ "picks.max_value_bytes", 1 },
    };
    for (cases, 0..) |case, index| {
        _ = try client_module.actions.executeAction(client, .{ .pick = @intCast(index) }, .binding);
        try client_module.pick_list.finish(client, try receivePick(&harness));
        try std.testing.expectEqual(data.PickListState.Phase.ready, client.model.pick_list.phase);
        try std.testing.expectEqual(case[1], client.model.pick_list.items.count);
        try std.testing.expect(client.model.limit_reaches.find(case[0]) != null);

        _ = try client_module.name_prompt.inputPrompt(client, .{ .key = .{ .code = .escape } });
    }
}

test "a list closed before its command finishes drops the late options" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try fixtures.reloadConfiguration(&harness, try fixtures.testingConfigAdoptionSource(1,
        \\local telar = require("telar")
        \\return { api_version = 2, client = { picks = {
        \\  late = telar.pick({ command = { "/bin/sh", "-c", "sleep 0.2; printf late" }, on_select = { "/bin/sh", "-c", ":", "{}" } }),
        \\} } }
    ));

    _ = try client_module.actions.executeAction(client, .{ .pick = 0 }, .binding);
    _ = try client_module.name_prompt.inputPrompt(client, .{ .key = .{ .code = .escape } });
    const version = client.model.version().prompt;
    try client_module.pick_list.finish(client, try receivePick(&harness));
    try std.testing.expectEqual(data.PickListState.Phase.closed, client.model.pick_list.phase);
    try std.testing.expectEqual(@as(u16, 0), client.model.pick_list.items.count);
    try std.testing.expectEqual(version, client.model.version().prompt);
}

test "a failing on_select publishes a diagnostic and refreshes nothing" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try fixtures.reloadConfiguration(&harness, try fixtures.testingConfigAdoptionSource(1,
        \\local telar = require("telar")
        \\return { api_version = 2, client = { picks = {
        \\  broken = telar.pick({ title = "Broken", items = { "one" }, on_select = { "/bin/sh", "-c", "exit 4", "sh", "{}" } }),
        \\} } }
    ));

    _ = try client_module.actions.executeAction(client, .{ .pick = 0 }, .binding);
    try pressEnter(client);
    const deadlines = client.model.bar_updates.deadlines;
    try client_module.pick_list.finish(client, try receivePick(&harness));
    try std.testing.expectEqualStrings("pick 'broken' on_select exited with an error", data.client_diagnostic.shown(&client.model).?);
    try std.testing.expectEqualDeep(deadlines, client.model.bar_updates.deadlines);
}

test "configuration rejects a pick without a choice argument or with a bad option" {
    const cases = [_][]const u8{
        \\local telar = require("telar")
        \\return { api_version = 2, client = { picks = { p = telar.pick({ items = { "a" }, on_select = { "/bin/echo", "a{}" } }) } } }
        ,
        \\local telar = require("telar")
        \\return { api_version = 2, client = { picks = { p = telar.pick({ items = { "a" }, on_select = { "{}" } }) } } }
        ,
        \\local telar = require("telar")
        \\return { api_version = 2, client = { picks = { p = telar.pick({ items = { "a\nb" }, on_select = { "/bin/echo", "{}" } }) } } }
        ,
        \\local telar = require("telar")
        \\return { api_version = 2, client = { picks = { p = telar.pick({ on_select = { "/bin/echo", "{}" } }) } } }
        ,
        \\local telar = require("telar")
        \\return { api_version = 2, client = { keybindings = { telar.bind({ "p" }, telar.action.pick("missing")) } } }
        ,
    };
    for (cases) |source| {
        var diagnostic: data.Diagnostic = .{};
        const loaded = client_module.Generation.loadSource(.{
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .diagnostic = &diagnostic,
        }, .{
            .source = source,
            .source_name = "@config.lua",
            .number = 1,
        });
        try std.testing.expectError(error.InvalidConfig, loaded);
        try std.testing.expect(diagnostic.len != 0);
    }
}

test "a second choice while on_select runs is refused and refresh can be turned off" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try fixtures.reloadConfiguration(&harness, try fixtures.testingConfigAdoptionSource(1,
        \\local telar = require("telar")
        \\return { api_version = 2, client = { picks = {
        \\  quiet = telar.pick({ items = { "one" }, refresh = false, on_select = { "/bin/sh", "-c", "sleep 0.3", "sh", "{}" } }),
        \\} } }
    ));

    _ = try client_module.actions.executeAction(client, .{ .pick = 0 }, .binding);
    try pressEnter(client);
    try std.testing.expect(client.model.pick_list.selecting != .none);

    _ = try client_module.actions.executeAction(client, .{ .pick = 0 }, .binding);
    try pressEnter(client);
    try std.testing.expectEqualStrings("pick 'quiet' is still running its last choice", data.client_diagnostic.shown(&client.model).?);

    const deadlines = client.model.bar_updates.deadlines;
    try client_module.pick_list.finish(client, try receivePick(&harness));
    try std.testing.expect(client.model.pick_list.selecting == .none);
    try std.testing.expectEqualDeep(deadlines, client.model.bar_updates.deadlines);
}

test "a reload while the list command runs fails the list instead of filling it" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const source =
        \\local telar = require("telar")
        \\return { api_version = 2, client = { picks = {
        \\  late = telar.pick({ command = { "/bin/sh", "-c", "sleep 0.2; printf late" }, on_select = { "/bin/sh", "-c", ":", "{}" } }),
        \\} } }
    ;
    _ = try fixtures.reloadConfiguration(&harness, try fixtures.testingConfigAdoptionSource(1, source));
    _ = try client_module.actions.executeAction(client, .{ .pick = 0 }, .binding);
    _ = try fixtures.reloadConfiguration(&harness, try fixtures.testingConfigAdoptionSource(2, source));

    try client_module.pick_list.finish(client, try receivePick(&harness));
    try std.testing.expectEqual(data.PickListState.Phase.failed, client.model.pick_list.phase);
    try std.testing.expectEqualStrings("the configuration changed; open the list again", client.model.pick_list.errorSlice());
    try std.testing.expectEqual(@as(u16, 0), client.model.pick_list.items.count);
}

test "another prompt replacing the palette drops the late options without running items" {
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try fixtures.reloadConfiguration(&harness, try fixtures.testingConfigAdoptionSource(1,
        \\local telar = require("telar")
        \\return { api_version = 2, client = { picks = {
        \\  late = telar.pick({
        \\    command = { "/bin/sh", "-c", "sleep 0.2; printf late" },
        \\    items = function() error("items ran for a replaced list") end,
        \\    on_select = { "/bin/sh", "-c", ":", "{}" },
        \\  }),
        \\} } }
    ));

    _ = try client_module.actions.executeAction(client, .{ .pick = 0 }, .binding);
    try std.testing.expect(client_module.name_prompt.openNamePrompt(&client.model, .goto_picker));
    try std.testing.expectEqual(data.PickListState.Phase.closed, client.model.pick_list.phase);

    // A palette closed some other way still drops what arrives.
    _ = try client_module.actions.executeAction(client, .{ .pick = 0 }, .effect);
    client.model.name_prompt.begin(.goto_picker);
    try client_module.pick_list.finish(client, try receivePick(&harness));
    try client_module.pick_list.finish(client, try receivePick(&harness));
    try std.testing.expectEqual(data.PickListState.Phase.closed, client.model.pick_list.phase);
    try std.testing.expectEqual(@as(u16, 0), client.model.pick_list.items.count);
    try std.testing.expect(data.client_diagnostic.shown(&client.model) == null);
}

test "a value that starts with a dash arrives as one argument and one that overflows argv is refused" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try absolutePath(&temp, &directory_buffer);
    var harness: ClientHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\local telar = require("telar")
        \\return {{ api_version = 2, client = {{ picks = {{
        \\  a_dash = telar.pick({{ items = {{ "-rf --help" }}, on_select = {{ "/bin/sh", "-c", 'printf %s "$1" > "$0/choice"', "{s}", "{{}}" }} }}),
        \\  b_wide = telar.pick({{ items = {{ {{ label = "wide", value = string.rep("v", 500) }} }}, on_select = {{ "/bin/echo", string.rep("a", 3800), "{{}}" }} }}),
        \\}} }} }}
    , .{directory});
    defer std.testing.allocator.free(source);
    _ = try fixtures.reloadConfiguration(&harness, try fixtures.testingConfigAdoptionSource(1, source));

    _ = try client_module.actions.executeAction(client, .{ .pick = 0 }, .binding);
    try pressEnter(client);
    try client_module.pick_list.finish(client, try receivePick(&harness));
    var written: [64]u8 = undefined;
    try std.testing.expectEqualStrings("-rf --help", try temp.dir.readFile(std.testing.io, "choice", &written));

    _ = try client_module.actions.executeAction(client, .{ .pick = 1 }, .binding);
    try pressEnter(client);
    try std.testing.expect(client.model.pick_list.selecting == .none);
    try std.testing.expectEqualStrings("pick 'b_wide': the choice does not fit on_select: BarCommandTooLong", data.client_diagnostic.shown(&client.model).?);
}

fn absolutePath(temp: *std.testing.TmpDir, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const len = try temp.dir.realPathFile(std.testing.io, ".", buffer);
    return buffer[0..len];
}

// Handles bar events until the command source at the bottom left shows
// `text`.
fn settleBar(harness: *ClientHarness, text: []const u8) !void {
    const client = harness.client;
    while (true) {
        const slot = client.model.bars.layout.slot(.bottom_left);
        if (slot.* == .content and slot.content.slice().len != 0 and std.mem.eql(u8, text, slot.content.text(slot.content.slice()[0].text))) {
            return;
        }

        _ = try client.update(try harness.receiveClient());
    }
}

// Handles other events until a pick command completes and hands it over.
fn receivePick(harness: *ClientHarness) !client_module.PickCommandCompletion {
    while (true) {
        switch (try harness.receiveClient()) {
            .pick_command => |completion| return completion,
            else => |message| _ = try harness.client.update(message),
        }
    }
}

fn typeText(client: *client_module.Client, text: []const u8) !void {
    _ = try client_module.name_prompt.inputPrompt(client, .{ .command = .{ .insert = text } });
}

fn pressEnter(client: *client_module.Client) !void {
    _ = try client_module.name_prompt.inputPrompt(client, .{ .key = .{ .code = .enter } });
}

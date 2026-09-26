//! Path picker flow proof through host input, runtime messages and the real client outbox.
const keyinput = @import("keyinput");
const core = @import("telar-core");
const TestHarness = @import("TestHarness.zig");
const std = @import("std");
const client_module = @import("telar-client");

fn press(client: *client_module.Client, code: keyinput.Key.Code) !void {
    _ = try client_module.name_prompt.inputPrompt(
        client,
        .{
            .key = .{
                .code = code,
            },
        },
    );
}

fn pressCtrl(client: *client_module.Client, letter: []const u8) !void {
    _ = try client_module.name_prompt.inputPrompt(
        client,
        .{
            .key = .{
                .code = .{
                    .char = keyinput.Char.init(letter),
                },
                .mods = .{
                    .ctrl = true,
                },
            },
        },
    );
}

fn answer(client: *client_module.Client, request: core.FindPaths, matches: []const core.PathMatch) !void {
    var buffer: [4096]u8 = undefined;
    const encoded = try core.encodePathResults(&buffer, .{
        .request_id = request.request_id,
        .root = request.root,
        .scanned = @intCast(matches.len),
        .matches = matches,
    });
    _ = try client_module.runtime_messages.handleServerMessage(client, try core.decodeServer(encoded));
}

test "the picker browses the pane's directory, drills in and out, and pastes the chosen path" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .pane_cwd = .{
                .pane_id = TestHarness.bootstrap_pane,
                .cwd = "/work/app",
            },
        },
    );

    _ = try client_module.actions.executeAction(
        client,
        .path_picker,
        .binding,
    );
    try std.testing.expect(client.model.name_prompt.active());
    try harness.settle();
    var buffer: [8192]u8 = undefined;
    const opened = (try harness.nextClientMessage(&buffer)).find_paths;
    try std.testing.expectEqualStrings("/work/app", opened.root);
    try std.testing.expectEqualStrings("", opened.query);
    try std.testing.expect(opened.refresh);
    try answer(client, opened, &.{
        .{
            .path = "src/",
            .kind = .directory,
        },
        .{
            .path = "README.md",
            .kind = .file,
        },
    });
    try std.testing.expectEqual(@as(u8, 2), client.model.path_picker.len);

    try pressCtrl(client, "j");
    try std.testing.expectEqual(@as(u16, 1), client.model.name_prompt.currentConst().?.selection());
    try pressCtrl(client, "k");
    try std.testing.expectEqual(@as(u16, 0), client.model.name_prompt.currentConst().?.selection());

    try press(client, .tab);
    try harness.settle();
    const inside = (try harness.nextClientMessage(&buffer)).find_paths;
    try std.testing.expectEqualStrings("/work/app/src", inside.root);
    try std.testing.expect(inside.refresh);

    try press(client, .back_tab);
    try harness.settle();
    const back = (try harness.nextClientMessage(&buffer)).find_paths;
    try std.testing.expectEqualStrings("/work/app", back.root);

    _ = try client_module.name_prompt.inputPrompt(
        client,
        .{
            .key = .{
                .code = .{
                    .char = keyinput.Char.init("m"),
                },
            },
        },
    );
    try harness.settle();
    const typed = (try harness.nextClientMessage(&buffer)).find_paths;
    try std.testing.expectEqualStrings("m", typed.query);
    try std.testing.expect(!typed.refresh);
    try answer(client, typed, &.{
        .{
            .path = "src/main.zig",
            .kind = .file,
            .positions = &.{4},
        },
    });

    try press(client, .enter);
    try std.testing.expect(!client.model.name_prompt.active());
    try harness.settle();
    while (true) {
        const message = try harness.receiveClientMessage(&buffer);
        if (message == .pane_input) {
            try std.testing.expectEqualStrings("src/main.zig", message.pane_input.bytes);
            break;
        }
    }
}

test "a stale reply cannot replace the page and a failure shows in the picker" {
    var harness: TestHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bootstrap();
    const client = harness.client;
    _ = try client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .pane_cwd = .{
                .pane_id = TestHarness.bootstrap_pane,
                .cwd = "/work",
            },
        },
    );

    _ = try client_module.actions.executeAction(
        client,
        .path_picker,
        .binding,
    );
    try harness.settle();
    var buffer: [8192]u8 = undefined;
    const first = (try harness.nextClientMessage(&buffer)).find_paths;
    _ = try client_module.name_prompt.inputPrompt(
        client,
        .{
            .key = .{
                .code = .{
                    .char = keyinput.Char.init("x"),
                },
            },
        },
    );
    try harness.settle();
    const second = (try harness.nextClientMessage(&buffer)).find_paths;
    try answer(
        client,
        first,
        &.{.{
            .path = "old",
            .kind = .file,
        }},
    );
    try std.testing.expectEqual(@as(u8, 0), client.model.path_picker.len);

    _ = try client_module.runtime_messages.handleServerMessage(
        client,
        .{
            .request_failed = .{
                .request_id = second.request_id,
                .code = .permission_denied,
                .message = "the directory cannot be read",
            },
        },
    );
    try std.testing.expectEqualStrings("the directory cannot be read", client.model.path_picker.errorSlice());
    try std.testing.expect(client.model.name_prompt.active());

    try press(client, .escape);
    try std.testing.expect(!client.model.name_prompt.active());
    try std.testing.expectEqual(core.PaneId.invalid, client.model.path_picker.pane_id);
}

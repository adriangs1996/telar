//! Keys the integration tests send, as a window would. `route*` hands a key
//! straight to the client's key routing, past the keymap; `press*` goes
//! through the keymap router first, so prefix bindings resolve to actions.
const keyinput = @import("keyinput");
const data = @import("model");
const std = @import("std");
const client_module = @import("telar-client");

/// Example: `try keys.routeChord(client, "ctrl+c");`
pub fn routeChord(client: *client_module.Client, chord: []const u8) !void {
    try routeKey(client, try keyinput.chord.parseKey(chord));
}

/// Example: `try keys.routeKey(client, .plain(.enter));`
pub fn routeKey(client: *client_module.Client, key: keyinput.Key) !void {
    _ = try client_module.key_routing.routeKeyInput(client, .{ .key = key });
}

/// Each character of `text`, routed in order.
/// Example: `try keys.routeText(client, "main");`
pub fn routeText(client: *client_module.Client, text: []const u8) !void {
    var characters = (try std.unicode.Utf8View.init(text)).iterator();
    while (characters.nextCodepointSlice()) |character| {
        try routeKey(client, .plain(.{ .char = keyinput.Char.init(character) }));
    }
}

/// One key through a keymap built from the client's configuration. A
/// binding runs its action; a sequence left pending is an error, since
/// each call builds a fresh router.
/// Example: `try keys.pressKey(client, .plain(.enter));`
pub fn pressKey(client: *client_module.Client, key: keyinput.Key) !void {
    var router = try client_module.key_router.build(client.routerConfig());
    const decision = router.routeEvent(.{
        .key = key,
        .now_ns = 0,
    }, .{
        .captures_keys = data.key_routing.captures(client_module.key_routing.keyRoutingAuthority(client)),
        .repeat_policy = null,
    });

    switch (decision) {
        .forward => |value| try routeKey(client, value),
        .action => |request| _ = try client_module.actions.executeAction(client, request.value, .binding),
        .replay, .pending, .discard => return error.UnexpectedKeyDecision,
    }
}

/// Each character of `text` through the keymap, as `pressKey` sends it.
/// Example: `try keys.typeText(client, "agents");`
pub fn typeText(client: *client_module.Client, text: []const u8) !void {
    var characters = (try std.unicode.Utf8View.init(text)).iterator();
    while (characters.nextCodepointSlice()) |character| {
        try pressKey(client, .plain(.{ .char = keyinput.Char.init(character) }));
    }
}

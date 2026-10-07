//! Window input admission, key and pointer routing, and gesture recovery.

const keyinput = @import("keyinput");
const client = @import("telar-client");
const data = @import("model");
const widget_routing = @import("widgets/interaction/routing.zig");
const Window = @import("telar-window");
pub const KeyInput = @FieldType(Window.Input, "key");
pub const ClipboardResult = @FieldType(Window.Input, "clipboard");
pub const PointerEvent = @FieldType(Window.Input, "pointer");
const WindowModel = @import("WindowModel.zig");

const MouseMask = enum(u8) {
    button_and_modifiers = 0b0001_1111,
};

/// Cancels a partial chord and its original widget before input changes owner.
/// Held physical keys retain their leases. Example: `cancelBinding(&gui.model);`
pub fn cancelBinding(model: *WindowModel) void {
    model.router.cancelSequence();
}

/// Opens a native paste on the widget that takes it or the shared route.
pub fn startPaste(model: *WindowModel, app: *client.Client) !void {
    _ = try applyInputDecision(model, app, model.router.interrupt());
    model.paste_route = if (try widget_routing.beginPaste(model, app)) .widget else .shared;

    if (model.paste_route == .shared) {
        _ = try client.paste_routing.start(app);
    }
}

pub fn pasteContent(model: *WindowModel, app: *client.Client, bytes: []const u8) !void {
    if (model.paste_route == .widget) {
        try widget_routing.paste(model, app, bytes);
    } else {
        _ = try client.paste_routing.content(app, bytes);
    }
}

pub fn applyInputDecision(model: *WindowModel, app: *client.Client, decision: client.key_router.Type.Decision) !keyinput.Control {
    switch (decision) {
        .forward => |value| {
            _ = try client.key_routing.routeKeyInput(
                app,
                .{
                    .key = value,
                },
            );
        },
        .replay => |value| {
            for (value.held_keys[0..value.held_key_len]) |held| {
                try deliverKey(app, held);
            }

            if (value.current_key) |current| {
                if (data.key_routing.captures(client.key_routing.keyRoutingAuthority(app))) {
                    _ = try client.key_routing.routeKeyInput(
                        app,
                        .{
                            .key = current,
                        },
                    );
                } else {
                    try deliverKey(app, current);
                }
            }
        },
        .action => |request| {
            const control = try executeAction(model, app, request.value);

            if (control == .continue_routing) {
                model.router.actionCompleted(request, client.repeatPolicy(request.value, client.actions.repeatPane(app)));
            }

            return control;
        },
        .pending, .discard => {},
    }

    return .continue_routing;
}

fn deliverKey(app: *client.Client, value: keyinput.Key) !void {
    _ = try client.key_routing.routeKeyInput(
        app,
        .{
            .key = value,
        },
    );
}

/// The goto and suggest keys open the native palette already prefixed, and
/// sidebar resize uses this window's pixel preference. Other actions keep the
/// shared routing. Copy mode retires first, as the shared native action
/// policy does.
fn executeAction(model: *WindowModel, app: *client.Client, value: data.actions.Action) !keyinput.Control {
    const prefix: data.command_palette.Prefix = switch (value) {
        .goto_picker => .goto,
        .suggest_command => .suggest,
        .resize_sidebar => |direction| {
            _ = try client.copy_mode.leaveCopyMode(app);

            if (model.sidebar.step(direction)) {
                model.chrome.invalidate();
            }

            return .continue_routing;
        },
        else => return client.actions.executeAction(app, value, .binding),
    };

    if (client.copy_mode.copyModeActive(app)) {
        _ = try client.copy_mode.leaveCopyMode(app);
    }

    _ = client.name_prompt.beginCommandPalette(&app.model, prefix);

    return .continue_routing;
}

/// Completes once, discarding a response whose original attachment is no
/// longer the focused terminal. Example: `if (takeTerminalClipboard(&gui.model, gui.app, result)) startPaste();`
pub fn takeTerminalClipboard(model: *WindowModel, app: *client.Client, result: ClipboardResult) bool {
    const clipboard = &model.terminal_clipboard;

    if (result.request_id != clipboard.request_id) {
        return false;
    }

    defer clipboard.request_id = 0;

    if (result.status != .success or result.target_id != 0 or result.generation != clipboard.generation or app.model.name_prompt.active() or data.copy_mode.isActive(&app.model) or !model.focused) {
        return false;
    }

    const tab = app.model.tabs.activeSlot() orelse return false;
    const pane = data.tab_layout.focusedPaneConst(&app.model, tab) orelse return false;

    return pane.id == clipboard.pane_id and pane.attachment_generation == clipboard.generation;
}

/// Resolves one pointer event against the presented overlays, the link
/// tooltip and the chrome hit map, taking each one's gesture on a press.
pub fn chromePointer(model: *WindowModel, app: *client.Client, event: keyinput.Mouse) client.ViewInteractionCommand {
    // A prompt can open before its first paint; it already owns the pointer.
    if (app.model.name_prompt.active() and model.overlays.presented().modal == null) {
        return .{
            .consumed = true,
        };
    }

    if (model.overlays.pointer(event)) |interaction| {
        return interaction;
    }

    if (model.pointer.hover.covers(event)) {
        if (event.kind == .press) {
            model.overlays.gesture = event.button & 3;
        }

        return .{
            .consumed = true,
        };
    }

    return model.chrome.pointer(event);
}

/// Closes existing gestures on focus loss, without assigning their releases
/// to chrome or to a pane that happens to be focused. Example: `try releasePointer(&gui.model, gui.app);`
pub fn releasePointer(model: *WindowModel, app: *client.Client) !void {
    const pointer = &model.pointer;

    pointer.hover.clear();
    pointer.link_gesture.cancel();
    defer pointer.owners = @splat(.shared);

    for (&pointer.owners, pointer.last) |*owner, last| {
        switch (owner.*) {
            .child => |*capture| {
                var released = last;
                released.kind = .release;
                released.button &= @intFromEnum(MouseMask.button_and_modifiers);
                try capture.deliver(app, released);
            },
            .link => {},
            .shared, .discarded => {},
        }
    }

    if (data.copy_mode.pointerSelection(&app.model)) |pointer_selection| {
        if (pointer_selection.dragging) {
            if (app.model.tabs.activeSlot()) |tab| {
                var released = pointer.last[@intFromEnum(PointerEvent.Button.left)];
                released.kind = .release;
                released.button = @intFromEnum(PointerEvent.Button.left);
                _ = try client.copy_mode_pointer.apply(
                    app,
                    tab,
                    released,
                );
            }
        }
    }
}

/// New widget and terminal gestures share the same delivered geometry guard.
/// Example: `const current = pointerGeometryMatches(gui.app);`
pub fn pointerGeometryMatches(app: *client.Client) bool {
    const delivered = app.presentation.delivered_geometry orelse return false;
    const snapshot = client.capture(
        &app.model,
        .{
            .geometry = app.geometry(),
        },
    );
    const current = client.Geometry.capture(snapshot);

    return delivered.matches(&current);
}

// A connected runtime can finish opening its first pane. Without a connection,
// input must still reach the machine picker and the window's other controls.
pub fn holdsStartupInput(app: *const client.Client) bool {
    return app.model.runtime_link.phase == .connected and app.model.startup.holdsInput();
}

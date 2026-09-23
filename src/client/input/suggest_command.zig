//! Suggest command: asks the runtime for a command suggestion and pastes or
//! submits it.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const name_prompt = @import("name_prompt.zig");
const pane_input = @import("../panes/pane_input.zig");
const Client = @import("../execution/Client.zig");

/// Sends one bounded request for the focused pane and awaits only its
/// reply. Without a focused pane there is nothing to give context, so the
/// palette shows a failure instead of asking.
/// Example: `try suggest_command.requestSuggestion(client, text);`
fn requestSuggestion(model: *data.ClientModel, text: []const u8) !void {
    const pane_id = suggestionPane(model) orelse {
        model.suggestion.expect(1);
        _ = model.suggestion.apply(
            .{
                .request_id = @enumFromInt(1),
                .status = .failed,
            },
        );
        return;
    };

    const request_id = try model.request_lifecycle.nextId();
    var owned: data.OwnedSuggestion = .{
        .request_id = request_id,
        .pane_id = pane_id,
        .text_len = @intCast(@min(text.len, data.OwnedSuggestion.max_text_bytes)),
    };
    @memcpy(owned.text[0..owned.text_len], text[0..owned.text_len]);

    model.suggestion.expect(core.raw(request_id));
    try model.to_runtime.push(
        .{
            .suggest_command = owned,
        },
    );
}

/// Pastes the landed suggestion into the focused pane. Runs after the
/// prompt closed, because `planPaneInput(.focused)` refuses input while a
/// prompt is active. Nothing is pasted unless a suggestion is ready.
/// Example: `try suggest_command.pasteSuggestion(client);`
pub fn pasteSuggestion(client: *Client) !void {
    const state = &client.model.suggestion;
    if (state.phase != .ready) {
        return;
    }

    _ = try pane_input.pasteExpression(client, state.textSlice());
}

/// Opens the palette with an empty request and no suggestion.
pub fn beginSuggestion(model: *data.ClientModel) !bool {
    if (!name_prompt.openNamePrompt(model, .suggest_palette)) {
        return false;
    }

    model.suggestion.begin();
    return true;
}

fn suggestionPane(model: *const data.ClientModel) ?core.PaneId {
    const active = model.tabs.activeSlot() orelse return null;
    const pane = data.tab_layout.focusedPaneConst(model, active) orelse return null;
    return pane.id;
}

/// Drops a landed or pending suggestion once its request text changed, so
/// the next Enter asks again instead of pasting a stale answer. Entering
/// the palette's `?` mode from another mode counts as a change.
pub fn discardEditedSuggestion(model: *data.ClientModel, before: data.PromptListSnapshot) void {
    const prompt = model.name_prompt.currentConst() orelse return;
    if (name_prompt.promptListSnapshot(&model.name_prompt).kind != .suggest) {
        return;
    }

    if (before.kind == .suggest and std.mem.eql(
        u8,
        before.textSlice(),
        prompt.paletteQuery(),
    )) {
        return;
    }

    model.suggestion.invalidate();
}

/// Enter asks while no suggestion is ready and the prompt stays open; once
/// a suggestion landed, Enter closes and pastes it.
pub fn submitSuggestion(model: *data.ClientModel, text: []const u8) !bool {
    if (model.suggestion.phase == .ready) {
        return true;
    }

    if (text.len == 0 or model.suggestion.phase == .waiting) {
        return false;
    }

    try requestSuggestion(model, text);
    return false;
}

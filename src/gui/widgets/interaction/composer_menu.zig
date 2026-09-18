const std = @import("std");
const client = @import("telar-client");
const GuiClient = @import("../../GuiClient.zig");
const Target = @import("Target.zig");
const Selector = @import("ComposerSelector.zig");
const Event = @import("../../input/event.zig").Event;

/// Revalidates the exact pane, catalog and draft settings represented on screen.
/// Example: `if (!composer_menu.eligible(gui, target)) return;`
pub fn eligible(gui: *const GuiClient, target: Target) bool {
    const selector = selectorOf(target) orelse return false;
    const model = gui.app.model.activeTabModelConst() orelse return false;
    const thread = client.ThreadView.capture(model, null, selector.pane_id) orelse return false;
    const pane = model.findConst(selector.pane_id) orelse return false;
    if (selector.kind == .recent and (thread.transcript == null or !thread.transcript.?.canResume())) {
        return false;
    }

    return !gui.app.model.name_prompt.active() and pane.attached and thread.kind == .agent and thread.attachment_generation == target.id.generation and thread.options_revision == selector.options_revision and thread.catalog_revision == selector.catalog_revision;
}

/// Opens or applies a delivered option. A retired menu cannot select by index.
/// Example: `try composer_menu.activate(gui, target);`
pub fn activate(gui: *GuiClient, target: Target) !void {
    if (!eligible(gui, target)) {
        close(gui);
        return;
    }

    const selector = selectorOf(target).?;
    const thread = client.ThreadView.capture(gui.app.model.activeTabModelConst().?, null, selector.pane_id).?;
    const options: @import("../ComposerOptions.zig") = .{ .thread = thread, .kind = selector.kind };
    const state = &gui.widgets.composer_menu;
    if (target.action == .composer_selector) {
        const same = if (state.selector) |open| std.meta.eql(open, selector) else false;
        if (same or options.count() == 0) {
            close(gui);
            return;
        }

        gui.widgets.cancelComposition();
        gui.input.cancelBinding();
        const model = gui.app.model.activeTabModel() orelse return;
        _ = try client.controllers.view_interactions.apply(&gui.app, model, .{ .intent = .{ .focus_pane = selector.pane_id }, .consumed = true });
        state.* = .{ .selector = selector, .attachment_generation = target.id.generation, .generation = state.generation +% 1, .anchor = target.bounds, .selected = options.selected() };
        state.reveal(options.count());
        gui.widgets.dispatcher.revision +%= 1;
        return;
    }

    const choice = target.action.composer_choice;
    const open = state.selector orelse return;
    if (state.generation != choice.menu_generation or !std.meta.eql(open, choice.selector) or choice.index >= options.count()) {
        return;
    }

    switch (selector.kind) {
        .recent => try client.agent_threads.resumeConversation(&gui.app, selector.pane_id, choice.index),
        .model => try client.agent_threads.selectModel(&gui.app, selector.pane_id, thread.transcript.?.models()[choice.index].idSlice()),
        .effort => try client.agent_threads.selectEffort(&gui.app, selector.pane_id, thread.transcript.?.findModel(thread.options.modelSlice()).?.efforts()[choice.index]),
        .access => try client.agent_threads.selectAccess(&gui.app, selector.pane_id, @enumFromInt(choice.index)),
    }

    close(gui);
}

/// Consumes menu input after the dispatcher establishes physical-key ownership.
/// Example: `if (try composer_menu.route(gui, event, route)) return true;`
pub fn route(gui: *GuiClient, event: Event, decision: @import("Route.zig")) !bool {
    const state = &gui.widgets.composer_menu;
    const selector = state.selector orelse return false;
    const fallback_lease = switch (event) {
        .key => |key| key.physical != null and key.phase != .press,
        .text => |text| text.physical != null and text.phase != .press,
        else => false,
    };
    if (fallback_lease and !decision.consumed) {
        return false;
    }

    const probe: Target = .{ .id = .{ .generation = state.attachment_generation }, .bounds = state.anchor, .action = .{ .composer_selector = selector } };
    if (!eligible(gui, probe) or event == .focus and !event.focus) {
        close(gui);
        return true;
    }

    const thread = client.ThreadView.capture(gui.app.model.activeTabModelConst().?, null, selector.pane_id).?;
    const options: @import("../ComposerOptions.zig") = .{ .thread = thread, .kind = selector.kind };
    if (event == .key and event.key.target_id != 0 and decision.target == null) {
        return true;
    }

    if (event == .key and event.key.phase == .repeat) {
        const owner = decision.target orelse return true;
        if (owner.action != .composer_choice or owner.action.composer_choice.menu_generation != state.generation or !std.meta.eql(owner.action.composer_choice.selector, selector)) {
            return true;
        }
    }

    if (event == .key and event.key.phase != .release) {
        switch (event.key.code) {
            .escape, .tab, .back_tab => close(gui),
            .up => move(gui, options.count(), false),
            .down => move(gui, options.count(), true),
            .home => {
                state.selected = 0;
                state.reveal(options.count());
                gui.widgets.dispatcher.revision +%= 1;
            },
            .end => {
                state.selected = options.count() -| 1;
                state.reveal(options.count());
                gui.widgets.dispatcher.revision +%= 1;
            },
            .enter => {
                for (gui.widgets.dispatcher.maps.presented().targets[0..gui.widgets.dispatcher.maps.presented().len]) |target| {
                    if (target.action == .composer_choice and target.action.composer_choice.menu_generation == state.generation and target.action.composer_choice.index == state.selected) {
                        try activate(gui, target);
                        break;
                    }
                }
            },
            else => {},
        }

        return true;
    }

    if (event == .scroll or event == .pointer and (event.pointer.kind == .scroll_up or event.pointer.kind == .scroll_down)) {
        const forward = if (event == .scroll) event.scroll.delta_y > 0 else event.pointer.kind == .scroll_down;
        move(gui, options.count(), forward);
        return true;
    }

    if (event == .pointer) {
        if (decision.target) |target| {
            if (target.action == .composer_choice or target.action == .composer_selector) {
                if (event.pointer.kind == .release and event.pointer.button == .left and target.contains(.{ event.pointer.x, event.pointer.y })) {
                    try activate(gui, target);
                } else if (event.pointer.kind == .move and target.action == .composer_choice) {
                    state.selected = target.action.composer_choice.index;
                    gui.widgets.dispatcher.revision +%= 1;
                }

                return true;
            }

            if (target.action == .custom and target.action.custom == 0x434d) {
                return true;
            }
        }

        if (event.pointer.kind == .press) {
            gui.widgets.dispatcher.discardPointer(event.pointer.button);
            close(gui);
        }
    }

    return true;
}

fn move(gui: *GuiClient, count: u8, forward: bool) void {
    const state = &gui.widgets.composer_menu;
    state.selected = if (forward) @min(state.selected +| 1, count -| 1) else state.selected -| 1;
    state.reveal(count);
    gui.widgets.dispatcher.revision +%= 1;
}

fn close(gui: *GuiClient) void {
    const selector = gui.widgets.composer_menu.selector;
    gui.widgets.composer_menu.selector = null;
    gui.widgets.dispatcher.revision +%= 1;
    const pane_id = if (selector) |value| value.pane_id else return;
    for (gui.widgets.dispatcher.maps.presented().targets[0..gui.widgets.dispatcher.maps.presented().len]) |target| {
        if (target.action == .composer and target.action.composer == pane_id) {
            _ = gui.widgets.dispatcher.focus(target.id);
            break;
        }
    }
}

fn selectorOf(target: Target) ?Selector {
    return switch (target.action) {
        .composer_selector => |selector| selector,
        .composer_choice => |choice| choice.selector,
        else => null,
    };
}

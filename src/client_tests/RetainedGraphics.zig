//! The harness's stand-in for a window's image store: which panes show
//! graphics, which panes hold images, and how many commands arrived. A pane
//! holds images from its first graphics command until the client clears
//! it. Pixels themselves are not kept.
const data = @import("model");
const core = @import("telar-core");
const client_module = @import("telar-client");
const RetainedGraphics = @This();

const max_hidden = 16;
const max_image_panes = 16;

hidden: [max_hidden]core.PaneId = undefined,
hidden_count: usize = 0,
image_panes: [max_image_panes]core.PaneId = undefined,
image_pane_count: usize = 0,
commands: usize = 0,

pub fn port(self: *RetainedGraphics) client_module.GraphicsRetention {
    return .{
        .context = self,
        .apply_fn = apply,
        .clear_pane_fn = clearPane,
        .set_pane_visible_fn = setVisible,
        .pane_visible_fn = visible,
        .has_pane_graphics_fn = hasGraphics,
        .ingress_version_fn = ingress,
        .peek_credit_fn = peekCredit,
        .consume_credit_fn = consumeCredit,
    };
}

/// Marks a pane as holding an image without a command.
/// Example: `try harness.graphics.holdImage(pane_id);`
pub fn holdImage(self: *RetainedGraphics, pane_id: core.PaneId) !void {
    if (self.holdsImage(pane_id)) {
        return;
    }

    if (self.image_pane_count == max_image_panes) {
        return error.TooManyImagePanes;
    }

    self.image_panes[self.image_pane_count] = pane_id;
    self.image_pane_count += 1;
}

pub fn holdsImage(self: *const RetainedGraphics, pane_id: core.PaneId) bool {
    for (self.image_panes[0..self.image_pane_count]) |pane| {
        if (pane == pane_id) {
            return true;
        }
    }

    return false;
}

pub fn setPaneVisible(self: *RetainedGraphics, pane_id: core.PaneId, value: bool) !void {
    for (self.hidden[0..self.hidden_count], 0..) |hidden, index| {
        if (hidden == pane_id) {
            if (value) {
                self.hidden[index] = self.hidden[self.hidden_count - 1];
                self.hidden_count -= 1;
            }

            return;
        }
    }

    if (!value) {
        if (self.hidden_count == max_hidden) {
            return error.TooManyHiddenPanes;
        }

        self.hidden[self.hidden_count] = pane_id;
        self.hidden_count += 1;
    }
}

fn from(context: *anyopaque) *RetainedGraphics {
    return @ptrCast(@alignCast(context));
}

fn apply(context: *anyopaque, command: data.PaneGraphicsCommand) !void {
    const self = from(context);
    self.commands += 1;
    try self.holdImage(command.paneId());
}

fn clearPane(context: *anyopaque, pane_id: core.PaneId) void {
    const self = from(context);
    for (self.image_panes[0..self.image_pane_count], 0..) |pane, index| {
        if (pane == pane_id) {
            self.image_panes[index] = self.image_panes[self.image_pane_count - 1];
            self.image_pane_count -= 1;
            return;
        }
    }
}

fn setVisible(context: *anyopaque, pane_id: core.PaneId, value: bool) !void {
    try from(context).setPaneVisible(pane_id, value);
}

fn visible(context: *anyopaque, pane_id: core.PaneId) bool {
    const self = from(context);
    for (self.hidden[0..self.hidden_count]) |hidden| {
        if (hidden == pane_id) {
            return false;
        }
    }

    return true;
}

fn hasGraphics(context: *anyopaque, pane_id: core.PaneId) bool {
    return from(context).holdsImage(pane_id);
}

fn ingress(context: *anyopaque) u64 {
    return from(context).commands;
}

fn peekCredit(_: *anyopaque) ?client_module.GraphicsCredit {
    return null;
}

fn consumeCredit(_: *anyopaque, _: client_module.GraphicsCredit) void {}

//! The harness's stand-in for a window's image store: which panes show
//! graphics, and how many commands arrived. Images themselves are not kept.
const data = @import("model");
const core = @import("telar-core");
const client_module = @import("telar-client");
const RetainedGraphics = @This();

const max_hidden = 16;

hidden: [max_hidden]core.PaneId = undefined,
hidden_count: usize = 0,
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

fn apply(context: *anyopaque, _: data.PaneGraphicsCommand) !void {
    from(context).commands += 1;
}

fn clearPane(_: *anyopaque, _: core.PaneId) void {}

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

fn hasGraphics(_: *anyopaque, _: core.PaneId) bool {
    return false;
}

fn ingress(context: *anyopaque) u64 {
    return from(context).commands;
}

fn peekCredit(_: *anyopaque) ?client_module.GraphicsCredit {
    return null;
}

fn consumeCredit(_: *anyopaque, _: client_module.GraphicsCredit) void {}

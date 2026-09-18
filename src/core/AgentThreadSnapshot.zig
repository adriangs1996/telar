const agent_thread = @import("agent_thread.zig");
const AgentThreadItem = @import("AgentThreadItem.zig");
const AgentApprovalRequest = @import("AgentApprovalRequest.zig");
const PaneId = @import("schema/id.zig").PaneId;
const std = @import("std");
const AgentModel = @import("AgentModel.zig");
const AgentOptions = @import("AgentOptions.zig");

pane_id: PaneId,
pane_generation: u64,
revision: u64 = 0,
thread_id: [agent_thread.max_item_reference_bytes]u8 = @splat(0),
thread_id_len: u8 = 0,
current_turn_id: [agent_thread.max_item_reference_bytes]u8 = @splat(0),
current_turn_id_len: u8 = 0,
status: agent_thread.Status = .starting,
item_storage: [agent_thread.max_items]AgentThreadItem = undefined,
item_count: u8 = 0,
text_storage: [agent_thread.max_text_bytes]u8 = @splat(0),
text_len: u32 = 0,
metadata_storage: [agent_thread.max_metadata_bytes]u8 = @splat(0),
metadata_len: u16 = 0,
pending_approval: ?AgentApprovalRequest = null,
truncated: bool = false,
model_storage: [agent_thread.max_models]AgentModel = @splat(.{}),
model_count: u8 = 0,
options: AgentOptions = .{},
recent: @import("RecentConversations.zig") = .{},
resumed: bool = false,
skills: @import("AgentSkills.zig") = .{},

/// Example: `drawThreadId(snapshot.threadId());`
pub fn threadId(snapshot: *const @This()) []const u8 {
    return snapshot.thread_id[0..snapshot.thread_id_len];
}

/// Example: `drawTurnId(snapshot.currentTurnId());`
pub fn currentTurnId(snapshot: *const @This()) []const u8 {
    return snapshot.current_turn_id[0..snapshot.current_turn_id_len];
}

/// Example: `for (snapshot.items()) |item| drawText(item.text(snapshot));`
pub fn items(snapshot: *const @This()) []const AgentThreadItem {
    return snapshot.item_storage[0..snapshot.item_count];
}

/// Resolves retained controls by runtime identity after streaming or eviction.
/// Example: `const item = snapshot.findItem(identity) orelse return;`
pub fn findItem(snapshot: *const @This(), identity: u64) ?*const AgentThreadItem {
    for (snapshot.items()) |*item| {
        if (item.identity == identity) {
            return item;
        }
    }

    return null;
}

/// Example: `for (snapshot.models()) |model| drawModel(model);`
pub fn models(snapshot: *const @This()) []const AgentModel {
    return snapshot.model_storage[0..snapshot.model_count];
}

/// Example: `const model = snapshot.findModel(options.modelSlice()) orelse return;`
pub fn findModel(snapshot: *const @This(), model_id: []const u8) ?*const AgentModel {
    for (snapshot.models()) |*model| {
        if (std.mem.eql(u8, model.idSlice(), model_id)) {
            return model;
        }
    }

    return null;
}

/// Admits only the provider's current model and effort combinations. Example: `if (!snapshot.accepts(options)) return error.InvalidAgentOptions;`
pub fn accepts(snapshot: *const @This(), options: AgentOptions) bool {
    if (!options.valid()) {
        return false;
    }

    const model = snapshot.findModel(options.modelSlice()) orelse return false;
    return model.supports(options.effort);
}

/// A resume can replace only an unused conversation. Example: `if (snapshot.canResume()) drawResume();`
pub fn canResume(snapshot: *const @This()) bool {
    if (snapshot.status != .ready or snapshot.resumed or snapshot.current_turn_id_len != 0) {
        return false;
    }

    for (snapshot.items()) |item| {
        if (item.role != .system) {
            return false;
        }
    }

    return true;
}

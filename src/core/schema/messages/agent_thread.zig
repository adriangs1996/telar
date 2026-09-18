//! Bounded typed controls and coalescible conversation snapshots.
const std = @import("std");
const Encoder = @import("../Encoder.zig");
const Decoder = @import("../Decoder.zig");
const codec = @import("../codec.zig");
const id = @import("../id.zig");
const tags = @import("tags.zig");
const GenericDerived = @import("../GenericDerived.zig").Type;
const limits = @import("../../agent_thread.zig");
const Snapshot = @import("../../AgentThreadSnapshot.zig");
const Item = @import("../../AgentThreadItem.zig");
const Approval = @import("../../AgentApprovalRequest.zig");
const Options = @import("../../AgentOptions.zig");
const Model = @import("../../AgentModel.zig");
const Effort = @import("../../AgentEffort.zig");
pub const SnapshotView = @import("AgentThreadSnapshotView.zig");

/// Example: `const bytes = try encodeAgentPrompt(buffer, prompt);`
pub fn encodeAgentPrompt(buffer: []u8, request: @import("AgentPrompt.zig")) ![]const u8 {
    try validateTarget(request);
    try validatePrompt(request.text, &request.images);
    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.agent_prompt));
    try encoder.writeInt(u64, id.raw(request.request_id));
    try encoder.writeInt(u64, id.raw(request.pane_id));
    try encoder.writeInt(u64, request.pane_generation);
    try encoder.writeSized16(request.text);
    try encodeOptions(&encoder, request.options, false);
    try encoder.writeByte(request.images.count);
    for (0..request.images.count) |index| {
        try encoder.writeSized16(request.images.path(index));
    }
    return encoder.finish();
}

/// Example: `const prompt = try decodeAgentPrompt(&decoder);`
pub fn decodeAgentPrompt(decoder: *Decoder) !@import("AgentPrompt.zig") {
    var request: @import("AgentPrompt.zig") = .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .pane_id = try id.pane(try decoder.readInt(u64)),
        .pane_generation = try decoder.readInt(u64),
        .text = try decoder.readSized16(),
        .options = try decodeOptions(decoder, false),
    };
    const count = try decoder.readByte();
    if (count > @import("../../AgentImages.zig").capacity) {
        return error.TooManyAgentImages;
    }

    for (0..count) |_| {
        try request.images.append(try decoder.readSized16());
    }

    try validateTarget(request);
    try validatePrompt(request.text, &request.images);
    return request;
}

/// Example: `const bytes = try encodeAgentInterrupt(buffer, request);`
pub fn encodeAgentInterrupt(buffer: []u8, request: @import("AgentInterrupt.zig")) ![]const u8 {
    try validateTarget(request);
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.agent_interrupt), buffer, request);
}

/// Example: `const bytes = try encodeAgentResume(buffer, request);`
pub fn encodeAgentResume(buffer: []u8, request: @import("AgentResume.zig")) ![]const u8 {
    try validateTarget(request);
    if (request.conversation_index >= @import("../../RecentConversations.zig").capacity) {
        return error.InvalidConversation;
    }

    return codec.encodeDerived(@intFromEnum(tags.ClientTag.agent_resume), buffer, request);
}

/// Example: `const bytes = try encodeAgentApproval(buffer, request);`
pub fn encodeAgentApproval(buffer: []u8, request: @import("AgentApproval.zig")) ![]const u8 {
    try validateTarget(request);
    if (request.approval_id == 0) {
        return error.InvalidApproval;
    }
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.agent_approval), buffer, request);
}

/// Example: `const bytes = try encodeQueryAgentThread(buffer, request);`
pub fn encodeQueryAgentThread(buffer: []u8, request: @import("QueryAgentThread.zig")) ![]const u8 {
    try validateTarget(request);
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.query_agent_thread), buffer, request);
}

/// Example: `const request = try decodeControl(AgentInterrupt, &decoder);`
pub fn decodeControl(comptime T: type, decoder: *Decoder) !T {
    const request = try GenericDerived(T).decode(decoder);
    try validateTarget(request);
    if (comptime @hasField(T, "approval_id")) {
        if (request.approval_id == 0) {
            return error.InvalidApproval;
        }
    }
    if (comptime @hasField(T, "conversation_index")) {
        if (request.conversation_index >= @import("../../RecentConversations.zig").capacity) {
            return error.InvalidConversation;
        }
    }
    return request;
}

fn validateTarget(request: anytype) !void {
    try codec.validateRequestId(request.request_id);
    try codec.validatePaneId(request.pane_id);
    if (request.pane_generation == 0) {
        return error.InvalidPaneGeneration;
    }
}

fn validatePrompt(text: []const u8, images: *const @import("../../AgentImagePaths.zig")) !void {
    try images.validate();
    if ((text.len == 0 and images.count == 0) or text.len > limits.max_prompt_bytes or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) {
        return error.InvalidPrompt;
    }
}

/// Encodes the used portion of one runtime-owned snapshot.
/// Example: `const bytes = try encodeAgentThreadSnapshot(buffer, snapshot);`.
pub fn encodeAgentThreadSnapshot(buffer: []u8, snapshot: *const Snapshot) ![]const u8 {
    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.agent_thread_snapshot));
    try encodeSnapshotBody(&encoder, snapshot);
    return encoder.finish();
}

/// Shares the validated snapshot representation with targeted history replies.
/// Example: `try encodeSnapshotBody(&encoder, &page.snapshot);`
pub fn encodeSnapshotBody(encoder: *Encoder, snapshot: *const Snapshot) !void {
    try codec.validatePaneId(snapshot.pane_id);
    if (snapshot.pane_generation == 0 or snapshot.item_count > limits.max_items or snapshot.text_len > limits.max_text_bytes or snapshot.metadata_len > limits.max_metadata_bytes or snapshot.thread_id_len > limits.max_item_reference_bytes or snapshot.current_turn_id_len > limits.max_item_reference_bytes) {
        return error.InvalidAgentSnapshot;
    }
    try validateMetadata(snapshot.threadId(), limits.max_item_reference_bytes);
    try validateMetadata(snapshot.currentTurnId(), limits.max_item_reference_bytes);
    const metadata = snapshot.metadata_storage[0..snapshot.metadata_len];
    try validateMetadata(metadata, limits.max_metadata_bytes);
    try encoder.writeInt(u64, id.raw(snapshot.pane_id));
    try encoder.writeInt(u64, snapshot.pane_generation);
    try encoder.writeInt(u64, snapshot.revision);
    try encoder.writeSized16(snapshot.threadId());
    try encoder.writeSized16(snapshot.currentTurnId());
    try encoder.writeByte(@intFromEnum(snapshot.status));
    try encoder.writeByte(@intFromBool(snapshot.truncated));
    try encoder.writeByte(snapshot.item_count);
    for (snapshot.items(), 0..) |item, index| {
        try validateItemIdentity(item, snapshot.items()[0..index]);
        if (item.text_offset > snapshot.text_len or item.text_len > snapshot.text_len - item.text_offset) {
            return error.InvalidAgentSnapshot;
        }
        try validateItemMetadata(item, metadata);
        try encoder.writeByte(@intFromEnum(item.role));
        try encodeItemMetadata(encoder, item);
        try encoder.writeInt(u32, item.text_offset);
        try encoder.writeInt(u32, item.text_len);
        try encoder.writeByte(@intFromBool(item.complete));
    }
    try encoder.writeSized32(snapshot.text_storage[0..snapshot.text_len]);
    try encoder.writeSized16(metadata);
    try encoder.writeByte(@intFromBool(snapshot.pending_approval != null));
    if (snapshot.pending_approval) |*approval| {
        if (approval.description_len > limits.max_approval_bytes or approval.id == 0) {
            return error.InvalidApproval;
        }
        try encoder.writeInt(u64, approval.id);
        try encoder.writeByte(@intFromEnum(approval.kind));
        try encoder.writeSized16(approval.text());
    }
    try snapshot.skills.encode(encoder);
    try snapshot.recent.encode(encoder);
    try encoder.writeByte(@intFromBool(snapshot.resumed));
    try encodeOptions(encoder, snapshot.options, true);
    if (snapshot.model_count > limits.max_models) {
        return error.InvalidAgentCatalog;
    }

    try encoder.writeByte(snapshot.model_count);
    for (snapshot.models()) |*model| {
        try validateModel(model);
        try encoder.writeSized16(model.idSlice());
        try encoder.writeSized16(model.labelSlice());
        try encoder.writeByte(model.effort_count);
        for (model.efforts()) |effort| {
            try encoder.writeSized16(effort.idSlice());
        }
        try encoder.writeSized16(model.default_effort.idSlice());
    }
}

/// Example: `const view = try decodeAgentThreadSnapshot(&decoder);`
pub fn decodeAgentThreadSnapshot(decoder: *Decoder) !SnapshotView {
    return decodeSnapshotBody(decoder, null);
}

/// Example: `const view = try decodeSnapshotBody(&decoder, output);`
pub fn decodeSnapshotBody(decoder: *Decoder, output: ?*Snapshot) !SnapshotView {
    const start = decoder.index;
    const pane_id = try id.pane(try decoder.readInt(u64));
    const generation = try decoder.readInt(u64);
    const revision = try decoder.readInt(u64);
    if (generation == 0) {
        return error.InvalidPaneGeneration;
    }
    const thread_id = try decoder.readSized16();
    const current_turn_id = try decoder.readSized16();
    try validateMetadata(thread_id, limits.max_item_reference_bytes);
    try validateMetadata(current_turn_id, limits.max_item_reference_bytes);
    const status = try decodeEnum(limits.Status, try decoder.readByte());
    const truncated = try decoder.readBool();
    const item_count = try decoder.readByte();
    if (item_count > limits.max_items) {
        return error.InvalidAgentSnapshot;
    }
    var items: [limits.max_items]Item = undefined;
    for (items[0..item_count]) |*item| {
        item.* = .{ .role = try decodeEnum(limits.Role, try decoder.readByte()) };
        try decodeItemMetadata(decoder, item);
        item.text_offset = try decoder.readInt(u32);
        item.text_len = try decoder.readInt(u32);
        item.complete = try decoder.readBool();
    }
    const text = try decoder.readSized32();
    if (text.len > limits.max_text_bytes or !std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidAgentSnapshot;
    }
    for (items[0..item_count], 0..) |item, index| {
        try validateItemIdentity(item, items[0..index]);
        if (item.text_offset > text.len or item.text_len > text.len - item.text_offset or !std.unicode.utf8ValidateSlice(text[item.text_offset..][0..item.text_len])) {
            return error.InvalidAgentSnapshot;
        }
    }
    const metadata = try decoder.readSized16();
    try validateMetadata(metadata, limits.max_metadata_bytes);
    for (items[0..item_count]) |item| {
        try validateItemMetadata(item, metadata);
    }
    var pending: ?Approval = null;
    if (try decoder.readBool()) {
        const approval_id = try decoder.readInt(u64);
        const kind = try decodeEnum(limits.ApprovalKind, try decoder.readByte());
        const description = try decoder.readSized16();
        if (approval_id == 0 or description.len > limits.max_approval_bytes or !std.unicode.utf8ValidateSlice(description)) {
            return error.InvalidApproval;
        }
        pending = .{ .id = approval_id, .kind = kind, .description_len = @intCast(description.len) };
        @memcpy(pending.?.description[0..description.len], description);
    }
    const skills = try @import("../../AgentSkills.zig").decode(decoder);
    const recent = try @import("../../RecentConversations.zig").decode(decoder);
    const resumed = try decoder.readBool();
    const options = try decodeOptions(decoder, true);
    const model_count = try decoder.readByte();
    if (model_count > limits.max_models) {
        return error.InvalidAgentCatalog;
    }

    var models: [limits.max_models]Model = @splat(.{});
    for (models[0..model_count], 0..) |*model, index| {
        const model_id = try decoder.readSized16();
        try validateLabel(model_id, limits.max_model_bytes, false);
        const label = try decoder.readSized16();
        try validateLabel(label, limits.max_model_label_bytes, false);
        model.id_len = @intCast(model_id.len);
        @memcpy(model.id[0..model_id.len], model_id);
        model.label_len = @intCast(label.len);
        @memcpy(model.label[0..label.len], label);
        model.effort_count = try decoder.readByte();
        if (model.effort_count == 0 or model.effort_count > limits.max_efforts) {
            return error.InvalidAgentCatalog;
        }

        for (model.effort_storage[0..model.effort_count]) |*effort| {
            effort.* = try Effort.init(try decoder.readSized16());
        }
        model.default_effort = try Effort.init(try decoder.readSized16());
        try validateModel(model);
        for (models[0..index]) |previous| {
            if (std.mem.eql(u8, previous.idSlice(), model.idSlice())) {
                return error.InvalidAgentCatalog;
            }
        }
    }
    if (output) |snapshot| {
        snapshot.* = .{
            .pane_id = pane_id,
            .pane_generation = generation,
            .revision = revision,
            .thread_id_len = @intCast(thread_id.len),
            .current_turn_id_len = @intCast(current_turn_id.len),
            .status = status,
            .truncated = truncated,
            .item_count = item_count,
            .text_len = @intCast(text.len),
            .metadata_len = @intCast(metadata.len),
            .pending_approval = pending,
            .options = options,
            .skills = skills,
            .recent = recent,
            .resumed = resumed,
            .model_count = model_count,
        };
        @memcpy(snapshot.item_storage[0..item_count], items[0..item_count]);
        @memcpy(snapshot.text_storage[0..text.len], text);
        @memcpy(snapshot.metadata_storage[0..metadata.len], metadata);
        @memcpy(snapshot.thread_id[0..thread_id.len], thread_id);
        @memcpy(snapshot.current_turn_id[0..current_turn_id.len], current_turn_id);
        @memcpy(snapshot.model_storage[0..model_count], models[0..model_count]);
    }
    return .{ .pane_id = pane_id, .pane_generation = generation, .revision = revision, .encoded = decoder.consumed(start) };
}

fn encodeItemMetadata(encoder: *Encoder, item: Item) !void {
    try encoder.writeInt(u64, item.identity);
    try encoder.writeInt(u64, item.turn_identity);
    try encoder.writeInt(u64, item.parent_identity);
    try encoder.writeByte(@intFromEnum(item.kind));
    try encoder.writeByte(@intFromEnum(item.status));
    try encoder.writeByte(@intFromEnum(item.phase));
    try encoder.writeInt(u32, item.fragment_offset);
    try encoder.writeByte(@intFromBool(item.fragment_start));
    try encoder.writeByte(@intFromBool(item.fragment_end));
    inline for (.{ "title", "detail", "reference", "source", "source_turn" }) |field| {
        try encoder.writeInt(u16, @field(item, field ++ "_offset"));
        try encoder.writeInt(u16, @field(item, field ++ "_len"));
    }
}

fn decodeItemMetadata(decoder: *Decoder, item: *Item) !void {
    item.identity = try decoder.readInt(u64);
    item.turn_identity = try decoder.readInt(u64);
    item.parent_identity = try decoder.readInt(u64);
    item.kind = try decodeEnum(limits.ItemKind, try decoder.readByte());
    item.status = try decodeEnum(limits.ItemStatus, try decoder.readByte());
    item.phase = try decodeEnum(limits.MessagePhase, try decoder.readByte());
    item.fragment_offset = try decoder.readInt(u32);
    item.fragment_start = try decoder.readBool();
    item.fragment_end = try decoder.readBool();
    inline for (.{ "title", "detail", "reference", "source", "source_turn" }) |field| {
        @field(item, field ++ "_offset") = try decoder.readInt(u16);
        @field(item, field ++ "_len") = try decoder.readInt(u16);
    }
}

fn validateMetadata(value: []const u8, maximum: usize) !void {
    if (value.len > maximum or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) {
        return error.InvalidAgentSnapshot;
    }
}

fn validateItemMetadata(item: Item, metadata: []const u8) !void {
    if (item.fragment_start != (item.fragment_offset == 0)) {
        return error.InvalidAgentSnapshot;
    }

    inline for (.{ "title", "detail", "reference", "source", "source_turn" }) |field| {
        const offset = @field(item, field ++ "_offset");
        const len = @field(item, field ++ "_len");
        if (offset > metadata.len or len > metadata.len - offset) {
            return error.InvalidAgentSnapshot;
        }
        try validateMetadata(metadata[offset..][0..len], @field(limits, "max_item_" ++ field ++ "_bytes"));
    }
}

fn validateItemIdentity(item: Item, prior: []const Item) !void {
    if (item.identity == 0 or item.parent_identity == item.identity) {
        return error.InvalidAgentSnapshot;
    }
    for (prior) |previous| {
        if (previous.identity == item.identity) {
            return error.InvalidAgentSnapshot;
        }
    }
}

fn encodeOptions(encoder: *Encoder, options: Options, allow_empty: bool) !void {
    if (options.model_len > limits.max_model_bytes or options.effort.id_len > limits.max_effort_bytes) {
        return error.InvalidAgentOptions;
    }

    try validateLabel(options.modelSlice(), limits.max_model_bytes, allow_empty);
    try validateLabel(options.effort.idSlice(), limits.max_effort_bytes, allow_empty and options.model_len == 0);
    try encoder.writeSized16(options.modelSlice());
    try encoder.writeSized16(options.effort.idSlice());
    try encoder.writeByte(@intFromEnum(options.access));
}

fn decodeOptions(decoder: *Decoder, allow_empty: bool) !Options {
    const model = try decoder.readSized16();
    const effort = try decoder.readSized16();
    try validateLabel(model, limits.max_model_bytes, allow_empty);
    try validateLabel(effort, limits.max_effort_bytes, allow_empty and model.len == 0);
    var options: Options = .{ .access = try decodeEnum(limits.Access, try decoder.readByte()) };
    if (model.len != 0) {
        try options.setModel(model);
    }
    if (effort.len != 0) {
        options.effort = try Effort.init(effort);
    }

    return options;
}

fn validateLabel(value: []const u8, maximum: usize, allow_empty: bool) !void {
    if ((!allow_empty and value.len == 0) or value.len > maximum or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) {
        return error.InvalidAgentOptions;
    }
}

fn validateModel(model: *const Model) !void {
    if (model.id_len > limits.max_model_bytes or model.label_len > limits.max_model_label_bytes or model.effort_count == 0 or model.effort_count > limits.max_efforts or model.default_effort.id_len > limits.max_effort_bytes) {
        return error.InvalidAgentCatalog;
    }

    try validateLabel(model.idSlice(), limits.max_model_bytes, false);
    try validateLabel(model.labelSlice(), limits.max_model_label_bytes, false);
    for (model.efforts(), 0..) |effort, index| {
        if (effort.id_len > limits.max_effort_bytes) {
            return error.InvalidAgentCatalog;
        }
        try validateLabel(effort.idSlice(), limits.max_effort_bytes, false);
        for (model.efforts()[0..index]) |previous| {
            if (effort.eql(previous)) {
                return error.InvalidAgentCatalog;
            }
        }
    }
    if (!model.supports(model.default_effort)) {
        return error.InvalidAgentCatalog;
    }
}

fn decodeEnum(comptime T: type, value: u8) !T {
    return std.enums.fromInt(T, value) orelse error.InvalidAgentTag;
}

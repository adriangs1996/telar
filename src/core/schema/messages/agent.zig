//! Agent lifecycle reports, acknowledgements and the projected agent
//! snapshot every runtime-state subscriber receives.

const std = @import("std");
const wire = @import("../wire.zig");
const id = @import("../id.zig");
const types = @import("../types.zig");
const codec = @import("../codec.zig");
const tags = @import("tags.zig");

const ClientTag = tags.ClientTag;
const ServerTag = tags.ServerTag;
const RequestId = id.RequestId;
const PaneId = id.PaneId;
const AgentProvider = types.AgentProvider;
const AgentAttachmentMarkers = types.AgentAttachmentMarkers;
const AgentStatus = types.AgentStatus;
const AgentReportState = types.AgentReportState;
const AgentSound = types.AgentSound;
const AgentSoundNotification = types.AgentSoundNotification;
const AgentSource = types.AgentSource;
const AgentAuthority = types.AgentAuthority;
const AgentTitleSource = types.AgentTitleSource;
const AgentTitleState = types.AgentTitleState;
const AgentSnapshotEntry = types.AgentSnapshotEntry;
const encodeDerived = codec.encodeDerived;
const validateRequestId = codec.validateRequestId;
const validatePaneId = codec.validatePaneId;
const validateBytes = codec.validateBytes;
const encodeTabLocation = codec.encodeTabLocation;
const decodeTabLocation = codec.decodeTabLocation;

/// Marks one exact agent generation as seen so a `done` status returns to
/// `ready`. A stale generation is ignored by the runtime.
pub const AcknowledgeAgent = struct {
    pane_id: PaneId,
    pane_generation: u64,
};

/// One-shot request for the current agent snapshot. The reply is the same
/// `agent_snapshot` message that runtime-state subscribers receive.
pub const QueryAgents = struct {
    request_id: RequestId,
};

/// An agent's own session identifier, reported by its lifecycle hooks so a
/// restart can resume the conversation. Only the exact pane generation that
/// hosts the agent accepts it.
pub const ReportAgentSession = struct {
    request_id: RequestId,
    pane_id: PaneId,
    pane_generation: u64,
    session: []const u8,
};

/// An official lifecycle report from an agent's hooks: its state and,
/// optionally, its own session reference. Only the exact pane generation
/// that hosts the agent accepts it.
pub const ReportAgent = struct {
    request_id: RequestId,
    pane_id: PaneId,
    pane_generation: u64,
    state: AgentReportState,
    session: []const u8 = "",
};

pub const AgentSnapshot = struct {
    revision: u64,
    entries: []const AgentSnapshotEntry,
};

pub const AgentSnapshotView = struct {
    revision: u64,
    entry_count: u16,
    encoded_entries: []const u8,

    pub fn entries(snapshot: AgentSnapshotView) AgentSnapshotIterator {
        return .{
            .decoder = .init(snapshot.encoded_entries),
            .remaining = snapshot.entry_count,
        };
    }
};

pub const AgentSnapshotIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *AgentSnapshotIterator) !?AgentSnapshotEntry {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        return try decodeAgentSnapshotEntry(&iterator.decoder);
    }
};

/// A session reference is an opaque token: letters, digits, `.`, `_`, `-`
/// and `:`, so it can never carry options or shell syntax into a relaunch.
///
/// ```zig
/// try validateSessionReference("019a2b3c-...");
/// ```
pub fn validateSessionReference(session: []const u8) !void {
    if (session.len == 0 or session.len > types.max_agent_session_reference_bytes) return error.InvalidSessionReference;
    for (session) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-' or byte == ':';
        if (!ok) return error.InvalidSessionReference;
    }
    if (session[0] == '-') return error.InvalidSessionReference;
}

/// A session title is bounded printable UTF-8: no C0 or DEL bytes, so the
/// value is safe in a wire frame, a checkpoint record and a host escape.
///
/// ```zig
/// try validateSessionTitle("Investigate proxy lifecycle");
/// ```
pub fn validateSessionTitle(title: []const u8) !void {
    if (title.len == 0 or title.len > types.max_agent_session_title_bytes or !std.unicode.utf8ValidateSlice(title)) {
        return error.InvalidSessionTitle;
    }

    for (title) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return error.InvalidSessionTitle;
        }
    }
}

pub fn encodeAcknowledgeAgent(buffer: []u8, message: AcknowledgeAgent) ![]const u8 {
    return encodeDerived(
        @intFromEnum(ClientTag.acknowledge_agent),
        AcknowledgeAgent,
        buffer,
        message,
    );
}

pub fn encodeQueryAgents(buffer: []u8, message: QueryAgents) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.query_agents), QueryAgents, buffer, message);
}

pub fn encodeReportAgentSession(buffer: []u8, message: ReportAgentSession) ![]const u8 {
    try validateRequestId(message.request_id);
    try validatePaneId(message.pane_id);
    try validateSessionReference(message.session);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.report_agent_session));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.pane_generation);
    try encoder.writeSized16(message.session);
    return encoder.finish();
}

pub fn decodeReportAgentSession(decoder: *wire.Decoder) !ReportAgentSession {
    const request_id = try id.request(try decoder.readInt(u64));
    const pane_id = try id.pane(try decoder.readInt(u64));
    const pane_generation = try decoder.readInt(u64);
    const session = try decoder.readSized16();
    try validateSessionReference(session);
    return .{
        .request_id = request_id,
        .pane_id = pane_id,
        .pane_generation = pane_generation,
        .session = session,
    };
}

pub fn encodeReportAgent(buffer: []u8, message: ReportAgent) ![]const u8 {
    try validateRequestId(message.request_id);
    try validatePaneId(message.pane_id);
    if (message.session.len != 0) try validateSessionReference(message.session);
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ClientTag.report_agent));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.pane_generation);
    try encoder.writeByte(@intFromEnum(message.state));
    try encoder.writeSized16(message.session);
    return encoder.finish();
}

pub fn decodeReportAgent(decoder: *wire.Decoder) !ReportAgent {
    const request_id = try id.request(try decoder.readInt(u64));
    const pane_id = try id.pane(try decoder.readInt(u64));
    const pane_generation = try decoder.readInt(u64);
    const state = std.enums.fromInt(AgentReportState, try decoder.readByte()) orelse
        return error.InvalidAgentReportState;
    const session = try decoder.readSized16();
    if (session.len != 0) try validateSessionReference(session);
    return .{
        .request_id = request_id,
        .pane_id = pane_id,
        .pane_generation = pane_generation,
        .state = state,
        .session = session,
    };
}

pub fn encodeAgentSound(buffer: []u8, message: AgentSoundNotification) ![]const u8 {
    try validatePaneId(message.pane_id);
    if (message.pane_generation == 0) return error.InvalidPaneGeneration;
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.agent_sound));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.pane_generation);
    try encoder.writeByte(@intFromEnum(message.sound));
    return encoder.finish();
}

pub fn decodeAgentSound(decoder: *wire.Decoder) !AgentSoundNotification {
    const notification: AgentSoundNotification = .{
        .pane_id = try id.pane(try decoder.readInt(u64)),
        .pane_generation = try decoder.readInt(u64),
        .sound = std.enums.fromInt(AgentSound, try decoder.readByte()) orelse
            return error.InvalidAgentSound,
    };
    if (notification.pane_generation == 0) return error.InvalidPaneGeneration;
    return notification;
}

pub fn encodeAgentSnapshot(buffer: []u8, message: AgentSnapshot) ![]const u8 {
    if (message.revision == 0) return error.InvalidAgentRevision;
    if (message.entries.len > types.max_agent_snapshot_entries) return error.TooManyAgentEntries;
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.agent_snapshot));
    try encoder.writeInt(u64, message.revision);
    try encoder.writeInt(u16, @intCast(message.entries.len));
    for (message.entries, 0..) |entry, index| {
        for (message.entries[0..index]) |previous| {
            if (previous.pane_id == entry.pane_id and
                previous.pane_generation == entry.pane_generation)
                return error.DuplicateAgentEntry;
        }
        try encodeAgentSnapshotEntry(&encoder, entry);
    }
    return encoder.finish();
}

pub fn decodeAgentSnapshot(decoder: *wire.Decoder) !AgentSnapshotView {
    const revision = try decoder.readInt(u64);
    if (revision == 0) return error.InvalidAgentRevision;
    const entry_count = try decoder.readInt(u16);
    if (entry_count > types.max_agent_snapshot_entries) return error.TooManyAgentEntries;
    const entries_start = decoder.index;
    var seen_ids: [types.max_agent_snapshot_entries]PaneId = undefined;
    var seen_generations: [types.max_agent_snapshot_entries]u64 = undefined;
    for (0..entry_count) |index| {
        const entry = try decodeAgentSnapshotEntry(decoder);
        for (seen_ids[0..index], seen_generations[0..index]) |pane_id, generation| {
            if (pane_id == entry.pane_id and generation == entry.pane_generation)
                return error.DuplicateAgentEntry;
        }
        seen_ids[index] = entry.pane_id;
        seen_generations[index] = entry.pane_generation;
    }
    return .{
        .revision = revision,
        .entry_count = entry_count,
        .encoded_entries = decoder.consumed(entries_start),
    };
}

fn encodeAgentSnapshotEntry(encoder: *wire.Encoder, entry: AgentSnapshotEntry) !void {
    try validatePaneId(entry.pane_id);
    if (entry.pane_generation == 0 or entry.pane_index == 0 or
        entry.sequence == 0 or entry.confidence > 100)
        return error.InvalidAgentEntry;
    if (entry.expires_at_ms < entry.observed_at_ms) return error.InvalidAgentExpiry;
    try validateAgentDisplayText(entry.workspace_label, types.max_agent_workspace_label_bytes, true);
    try validateAgentDisplayText(entry.tab_label, types.max_tab_label_bytes, true);
    try validateAgentDisplayText(entry.session_title, types.max_agent_session_title_bytes, true);
    try validateAgentDisplayText(entry.cwd_label, types.max_agent_cwd_label_bytes, true);
    try validateAgentDisplayText(entry.provider_name, types.max_agent_provider_name_bytes, true);
    try validateAgentDisplayText(entry.display_name, types.max_agent_display_name_bytes, true);
    try validateAgentDisplayText(entry.icon, types.max_agent_icon_bytes, true);
    try validateAgentProvider(entry.provider);
    try validateAgentTitle(entry);
    try encoder.writeInt(u64, id.raw(entry.pane_id));
    try encoder.writeInt(u64, entry.pane_generation);
    try encodeTabLocation(encoder, entry.location);
    try encoder.writeInt(u16, entry.pane_index);
    try encoder.writeInt(u32, entry.process_id);
    try encoder.writeBytes(&entry.session_id);
    try encoder.writeSized16(entry.workspace_label);
    try encoder.writeSized16(entry.tab_label);
    try encoder.writeSized16(entry.session_title);
    try encoder.writeByte(@intFromEnum(entry.title_source));
    try encoder.writeByte(@intFromEnum(entry.title_state));
    try encoder.writeSized16(entry.cwd_label);
    try encoder.writeByte(@intFromEnum(entry.provider));
    try encoder.writeSized16(entry.provider_name);
    try encoder.writeSized16(entry.display_name);
    try encoder.writeSized16(entry.icon);
    try encoder.writeByte(@intFromEnum(entry.attachments));
    try encoder.writeByte(@intFromEnum(entry.status));
    try encoder.writeByte(@intFromEnum(entry.source));
    try encoder.writeByte(@intFromEnum(entry.authority));
    try encoder.writeByte(entry.confidence);
    try encoder.writeInt(u64, entry.sequence);
    try encoder.writeInt(i64, entry.observed_at_ms);
    try encoder.writeInt(i64, entry.expires_at_ms);
}

fn decodeAgentSnapshotEntry(decoder: *wire.Decoder) !AgentSnapshotEntry {
    const entry: AgentSnapshotEntry = .{
        .pane_id = try id.pane(try decoder.readInt(u64)),
        .pane_generation = try decoder.readInt(u64),
        .location = try decodeTabLocation(decoder),
        .pane_index = try decoder.readInt(u16),
        .process_id = try decoder.readInt(u32),
        .session_id = (try decoder.readBytes(16))[0..16].*,
        .workspace_label = try decoder.readSized16(),
        .tab_label = try decoder.readSized16(),
        .session_title = try decoder.readSized16(),
        .title_source = std.enums.fromInt(AgentTitleSource, try decoder.readByte()) orelse
            return error.InvalidAgentTitleSource,
        .title_state = std.enums.fromInt(AgentTitleState, try decoder.readByte()) orelse
            return error.InvalidAgentTitleState,
        .cwd_label = try decoder.readSized16(),
        .provider = try decodeAgentProvider(try decoder.readByte()),
        .provider_name = try decoder.readSized16(),
        .display_name = try decoder.readSized16(),
        .icon = try decoder.readSized16(),
        .attachments = std.enums.fromInt(AgentAttachmentMarkers, try decoder.readByte()) orelse
            return error.InvalidAgentAttachments,
        .status = std.enums.fromInt(AgentStatus, try decoder.readByte()) orelse
            return error.InvalidAgentStatus,
        .source = std.enums.fromInt(AgentSource, try decoder.readByte()) orelse
            return error.InvalidAgentSource,
        .authority = std.enums.fromInt(AgentAuthority, try decoder.readByte()) orelse
            return error.InvalidAgentAuthority,
        .confidence = try decoder.readByte(),
        .sequence = try decoder.readInt(u64),
        .observed_at_ms = try decoder.readInt(i64),
        .expires_at_ms = try decoder.readInt(i64),
    };
    if (entry.pane_generation == 0 or entry.pane_index == 0 or
        entry.sequence == 0 or entry.confidence > 100)
        return error.InvalidAgentEntry;
    if (entry.expires_at_ms < entry.observed_at_ms) return error.InvalidAgentExpiry;
    try validateAgentDisplayText(entry.workspace_label, types.max_agent_workspace_label_bytes, true);
    try validateAgentDisplayText(entry.tab_label, types.max_tab_label_bytes, true);
    try validateAgentDisplayText(entry.session_title, types.max_agent_session_title_bytes, true);
    try validateAgentDisplayText(entry.cwd_label, types.max_agent_cwd_label_bytes, true);
    try validateAgentDisplayText(entry.provider_name, types.max_agent_provider_name_bytes, true);
    try validateAgentDisplayText(entry.display_name, types.max_agent_display_name_bytes, true);
    try validateAgentDisplayText(entry.icon, types.max_agent_icon_bytes, true);
    try validateAgentTitle(entry);
    return entry;
}

fn validateAgentProvider(provider: AgentProvider) !void {
    if (@intFromEnum(provider) > types.max_agent_provider_index) return error.InvalidAgentProvider;
}

fn decodeAgentProvider(value: u8) !AgentProvider {
    if (value > types.max_agent_provider_index) return error.InvalidAgentProvider;
    return @enumFromInt(value);
}

fn validateAgentDisplayText(bytes: []const u8, maximum: usize, empty_allowed: bool) !void {
    try validateBytes(bytes, maximum, empty_allowed);
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    for (bytes) |byte| if (byte < 0x20 or byte == 0x7f)
        return error.InvalidAgentDisplayText;
}

fn validateAgentTitle(entry: AgentSnapshotEntry) !void {
    switch (entry.title_source) {
        .telar => if (entry.title_state == .ready) return error.InvalidAgentTitle,
        .generated, .manual => if (entry.title_state != .ready or entry.session_title.len == 0)
            return error.InvalidAgentTitle,
        .terminal => if (entry.session_title.len == 0) return error.InvalidAgentTitle,
    }
}

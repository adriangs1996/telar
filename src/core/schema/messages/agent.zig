//! Agent lifecycle reports, acknowledgements and the projected agent
//! snapshot every runtime-state subscriber receives.

const types = @import("../types.zig");
const std = @import("std");
const AcknowledgeAgent = @import("AcknowledgeAgent.zig");
const codec = @import("../codec.zig");
const tags = @import("tags.zig");
const QueryAgents = @import("QueryAgents.zig");
const ReportAgentSession = @import("ReportAgentSession.zig");
const EncoderType = @import("../Encoder.zig");
const id = @import("../id.zig");
const DecoderType = @import("../Decoder.zig");
const ReportAgent = @import("ReportAgent.zig");
const ReportAgentCommand = @import("ReportAgentCommand.zig");
const ReportAgentTitle = @import("ReportAgentTitle.zig");
const AgentSoundNotification = @import("../AgentSoundNotification.zig");
const AgentSnapshot = @import("AgentSnapshot.zig");
const AgentSnapshotView = @import("AgentSnapshotView.zig");
const AgentSnapshotEntry = @import("../AgentSnapshotEntry.zig");

pub const AgentCommandPhase = enum(u8) {
    started = 0,
    finished = 1,
};

/// A session reference is an opaque token: letters, digits, `.`, `_`, `-`
/// and `:`, so it can never carry options or shell syntax into a relaunch.
///
/// ```zig
/// try validateSessionReference("019a2b3c-...");
/// ```
pub fn validateSessionReference(session: []const u8) !void {
    if (session.len == 0 or session.len > types.max_agent_session_reference_bytes) {
        return error.InvalidSessionReference;
    }
    for (session) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-' or byte == ':';
        if (!ok) {
            return error.InvalidSessionReference;
        }
    }
    if (session[0] == '-') {
        return error.InvalidSessionReference;
    }
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

/// Cuts a candidate title to the wire bound on a UTF-8 boundary. The result
/// still needs `validateSessionTitle`, which rejects control bytes.
///
/// ```zig
/// const title = truncateSessionTitle(&buffer, name);
/// ```
pub fn truncateSessionTitle(buffer: *[types.max_agent_session_title_bytes]u8, value: []const u8) []const u8 {
    var len = @min(value.len, buffer.len);
    while (len > 0 and len < value.len and (value[len] & 0xc0) == 0x80) {
        len -= 1;
    }

    @memcpy(buffer[0..len], value[0..len]);
    return buffer[0..len];
}

pub fn encodeAcknowledgeAgent(buffer: []u8, message: AcknowledgeAgent) ![]const u8 {
    return codec.encodeDerived(
        @intFromEnum(tags.ClientTag.acknowledge_agent),
        buffer,
        message,
    );
}

pub fn encodeQueryAgents(buffer: []u8, message: QueryAgents) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.query_agents), buffer, message);
}

pub fn encodeReportAgentSession(buffer: []u8, message: ReportAgentSession) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try codec.validatePaneId(message.pane_id);
    try validateSessionReference(message.session);
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.report_agent_session));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.pane_generation);
    try encoder.writeSized16(message.session);
    return encoder.finish();
}

pub fn decodeReportAgentSession(decoder: *DecoderType) !ReportAgentSession {
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
    try codec.validateRequestId(message.request_id);
    try codec.validatePaneId(message.pane_id);
    if (message.session.len != 0) {
        try validateSessionReference(message.session);
    }
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.report_agent));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.pane_generation);
    try codec.validateBytes(message.session_file, types.max_agent_session_file_bytes, true);
    try encoder.writeByte(@intFromEnum(message.state));
    try encoder.writeSized16(message.session);
    try encoder.writeSized16(message.session_file);
    try encoder.writeByte(@intFromEnum(message.session_file_kind));
    return encoder.finish();
}

pub fn decodeReportAgent(decoder: *DecoderType) !ReportAgent {
    const request_id = try id.request(try decoder.readInt(u64));
    const pane_id = try id.pane(try decoder.readInt(u64));
    const pane_generation = try decoder.readInt(u64);
    const state = std.enums.fromInt(types.AgentReportState, try decoder.readByte()) orelse
        return error.InvalidAgentReportState;
    const session = try decoder.readSized16();
    if (session.len != 0) {
        try validateSessionReference(session);
    }
    const session_file = try decoder.readSized16();
    try codec.validateBytes(session_file, types.max_agent_session_file_bytes, true);
    const session_file_kind = std.enums.fromInt(types.AgentSessionFileKind, try decoder.readByte()) orelse
        return error.InvalidAgentSessionFileKind;
    return .{
        .request_id = request_id,
        .pane_id = pane_id,
        .pane_generation = pane_generation,
        .state = state,
        .session = session,
        .session_file = session_file,
        .session_file_kind = session_file_kind,
    };
}

pub fn encodeReportAgentCommand(buffer: []u8, message: ReportAgentCommand) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try codec.validatePaneId(message.pane_id);
    try codec.validateBytes(message.provider, types.max_history_provider_bytes, false);
    try codec.validateBytes(message.tool_call_id, types.max_history_tool_call_id_bytes, true);
    try codec.validateBytes(message.command, types.max_history_command_bytes, false);
    try codec.validateBytes(message.cwd, types.max_cwd_bytes, true);
    if (message.session.len != 0) {
        try validateSessionReference(message.session);
    }
    if (message.phase == .started and message.exit_code != null) {
        return error.InvalidAgentCommandExitCode;
    }

    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.report_agent_command));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.pane_generation);
    try encoder.writeByte(@intFromEnum(message.phase));
    try encoder.writeSized16(message.provider);
    try encoder.writeSized16(message.tool_call_id);
    try encoder.writeSized32(message.command);
    try encoder.writeSized16(message.cwd);
    try encoder.writeSized16(message.session);
    try encoder.writeByte(@intFromBool(message.exit_code != null));
    if (message.exit_code) |exit_code| {
        try encoder.writeInt(i32, exit_code);
    }
    return encoder.finish();
}

pub fn decodeReportAgentCommand(decoder: *DecoderType) !ReportAgentCommand {
    const request_id = try id.request(try decoder.readInt(u64));
    const pane_id = try id.pane(try decoder.readInt(u64));
    const pane_generation = try decoder.readInt(u64);
    const phase = std.enums.fromInt(AgentCommandPhase, try decoder.readByte()) orelse return error.InvalidAgentCommandPhase;
    const provider = try decoder.readSized16();
    const tool_call_id = try decoder.readSized16();
    const command = try decoder.readSized32();
    const cwd = try decoder.readSized16();
    const session = try decoder.readSized16();
    const has_exit_code = try decoder.readBool();
    const exit_code = if (has_exit_code) try decoder.readInt(i32) else null;
    try codec.validateBytes(provider, types.max_history_provider_bytes, false);
    try codec.validateBytes(tool_call_id, types.max_history_tool_call_id_bytes, true);
    try codec.validateBytes(command, types.max_history_command_bytes, false);
    try codec.validateBytes(cwd, types.max_cwd_bytes, true);
    if (session.len != 0) {
        try validateSessionReference(session);
    }
    if (phase == .started and exit_code != null) {
        return error.InvalidAgentCommandExitCode;
    }
    return .{
        .request_id = request_id,
        .pane_id = pane_id,
        .pane_generation = pane_generation,
        .phase = phase,
        .provider = provider,
        .tool_call_id = tool_call_id,
        .command = command,
        .cwd = cwd,
        .session = session,
        .exit_code = exit_code,
    };
}

pub fn encodeReportAgentTitle(buffer: []u8, message: ReportAgentTitle) ![]const u8 {
    try codec.validateRequestId(message.request_id);
    try codec.validatePaneId(message.pane_id);
    if (message.title.len != 0) {
        try validateSessionTitle(message.title);
    }

    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.report_agent_title));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.pane_generation);
    try encoder.writeSized16(message.title);
    return encoder.finish();
}

pub fn decodeReportAgentTitle(decoder: *DecoderType) !ReportAgentTitle {
    const request_id = try id.request(try decoder.readInt(u64));
    const pane_id = try id.pane(try decoder.readInt(u64));
    const pane_generation = try decoder.readInt(u64);
    const title = try decoder.readSized16();
    if (title.len != 0) {
        try validateSessionTitle(title);
    }

    return .{
        .request_id = request_id,
        .pane_id = pane_id,
        .pane_generation = pane_generation,
        .title = title,
    };
}

pub fn encodeAgentSound(buffer: []u8, message: AgentSoundNotification) ![]const u8 {
    try codec.validatePaneId(message.pane_id);
    if (message.pane_generation == 0) {
        return error.InvalidPaneGeneration;
    }
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.agent_sound));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.pane_generation);
    try encoder.writeByte(@intFromEnum(message.sound));
    return encoder.finish();
}

pub fn decodeAgentSound(decoder: *DecoderType) !AgentSoundNotification {
    const notification: AgentSoundNotification = .{
        .pane_id = try id.pane(try decoder.readInt(u64)),
        .pane_generation = try decoder.readInt(u64),
        .sound = std.enums.fromInt(types.AgentSound, try decoder.readByte()) orelse
            return error.InvalidAgentSound,
    };
    if (notification.pane_generation == 0) {
        return error.InvalidPaneGeneration;
    }
    return notification;
}

pub fn encodeAgentSnapshot(buffer: []u8, message: AgentSnapshot) ![]const u8 {
    if (message.revision == 0) {
        return error.InvalidAgentRevision;
    }
    if (message.entries.len > types.max_agent_snapshot_entries) {
        return error.TooManyAgentEntries;
    }
    var encoder = EncoderType.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.agent_snapshot));
    try encoder.writeInt(u64, message.revision);
    try encoder.writeInt(u16, @intCast(message.entries.len));
    for (message.entries, 0..) |entry, index| {
        for (message.entries[0..index]) |previous| {
            if (previous.pane_id == entry.pane_id and
                previous.pane_generation == entry.pane_generation)
            {
                return error.DuplicateAgentEntry;
            }
        }
        try encodeAgentSnapshotEntry(&encoder, entry);
    }
    return encoder.finish();
}

pub fn decodeAgentSnapshot(decoder: *DecoderType) !AgentSnapshotView {
    const revision = try decoder.readInt(u64);
    if (revision == 0) {
        return error.InvalidAgentRevision;
    }
    const entry_count = try decoder.readInt(u16);
    if (entry_count > types.max_agent_snapshot_entries) {
        return error.TooManyAgentEntries;
    }
    const entries_start = decoder.index;
    var seen_ids: [types.max_agent_snapshot_entries]id.PaneId = undefined;
    var seen_generations: [types.max_agent_snapshot_entries]u64 = undefined;
    for (0..entry_count) |index| {
        const entry = try decodeAgentSnapshotEntry(decoder);
        for (seen_ids[0..index], seen_generations[0..index]) |pane_id, generation| {
            if (pane_id == entry.pane_id and generation == entry.pane_generation) {
                return error.DuplicateAgentEntry;
            }
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

fn encodeAgentSnapshotEntry(encoder: *EncoderType, entry: AgentSnapshotEntry) !void {
    try codec.validatePaneId(entry.pane_id);
    if (entry.pane_generation == 0 or entry.pane_index == 0 or
        entry.sequence == 0 or entry.confidence > 100)
    {
        return error.InvalidAgentEntry;
    }
    if (entry.expires_at_ms < entry.observed_at_ms) {
        return error.InvalidAgentExpiry;
    }
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
    try codec.encodeTabLocation(encoder, entry.location);
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

pub fn decodeAgentSnapshotEntry(decoder: *DecoderType) !AgentSnapshotEntry {
    const entry: AgentSnapshotEntry = .{
        .pane_id = try id.pane(try decoder.readInt(u64)),
        .pane_generation = try decoder.readInt(u64),
        .location = try codec.decodeTabLocation(decoder),
        .pane_index = try decoder.readInt(u16),
        .process_id = try decoder.readInt(u32),
        .session_id = (try decoder.readBytes(16))[0..16].*,
        .workspace_label = try decoder.readSized16(),
        .tab_label = try decoder.readSized16(),
        .session_title = try decoder.readSized16(),
        .title_source = std.enums.fromInt(types.AgentTitleSource, try decoder.readByte()) orelse
            return error.InvalidAgentTitleSource,
        .title_state = std.enums.fromInt(types.AgentTitleState, try decoder.readByte()) orelse
            return error.InvalidAgentTitleState,
        .cwd_label = try decoder.readSized16(),
        .provider = try decodeAgentProvider(try decoder.readByte()),
        .provider_name = try decoder.readSized16(),
        .display_name = try decoder.readSized16(),
        .icon = try decoder.readSized16(),
        .attachments = std.enums.fromInt(types.AgentAttachmentMarkers, try decoder.readByte()) orelse
            return error.InvalidAgentAttachments,
        .status = std.enums.fromInt(types.AgentStatus, try decoder.readByte()) orelse
            return error.InvalidAgentStatus,
        .source = std.enums.fromInt(types.AgentSource, try decoder.readByte()) orelse
            return error.InvalidAgentSource,
        .authority = std.enums.fromInt(types.AgentAuthority, try decoder.readByte()) orelse
            return error.InvalidAgentAuthority,
        .confidence = try decoder.readByte(),
        .sequence = try decoder.readInt(u64),
        .observed_at_ms = try decoder.readInt(i64),
        .expires_at_ms = try decoder.readInt(i64),
    };
    if (entry.pane_generation == 0 or entry.pane_index == 0 or
        entry.sequence == 0 or entry.confidence > 100)
    {
        return error.InvalidAgentEntry;
    }
    if (entry.expires_at_ms < entry.observed_at_ms) {
        return error.InvalidAgentExpiry;
    }
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

fn validateAgentProvider(provider: types.AgentProvider) !void {
    if (@intFromEnum(provider) > types.max_agent_provider_index) {
        return error.InvalidAgentProvider;
    }
}

fn decodeAgentProvider(value: u8) !types.AgentProvider {
    if (value > types.max_agent_provider_index) {
        return error.InvalidAgentProvider;
    }
    return @enumFromInt(value);
}

fn validateAgentDisplayText(bytes: []const u8, maximum: usize, empty_allowed: bool) !void {
    try codec.validateBytes(bytes, maximum, empty_allowed);
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        return error.InvalidUtf8;
    }
    for (bytes) |byte| if (byte < 0x20 or byte == 0x7f)
        return error.InvalidAgentDisplayText;
}

fn validateAgentTitle(entry: AgentSnapshotEntry) !void {
    switch (entry.title_source) {
        .telar => if (entry.title_state == .ready) return error.InvalidAgentTitle,
        .generated, .manual, .agent => if (entry.title_state != .ready or entry.session_title.len == 0)
            return error.InvalidAgentTitle,
        .terminal => if (entry.session_title.len == 0) return error.InvalidAgentTitle,
    }
}

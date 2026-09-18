const agent_thread = @import("agent_thread.zig");
const AgentThreadSnapshot = @import("AgentThreadSnapshot.zig");

role: agent_thread.Role,
identity: u64 = 0,
turn_identity: u64 = 0,
parent_identity: u64 = 0,
kind: agent_thread.ItemKind = .message,
status: agent_thread.ItemStatus = .pending,
phase: agent_thread.MessagePhase = .unknown,
text_offset: u32 = 0,
text_len: u32 = 0,
complete: bool = false,
title_offset: u16 = 0,
title_len: u16 = 0,
detail_offset: u16 = 0,
detail_len: u16 = 0,
reference_offset: u16 = 0,
reference_len: u16 = 0,
source_offset: u16 = 0,
source_len: u16 = 0,
source_turn_offset: u16 = 0,
source_turn_len: u16 = 0,
fragment_offset: u32 = 0,
fragment_start: bool = true,
fragment_end: bool = true,

/// Identifies a provider item within its source turn in live and historical pages.
/// Example: `const anchor = item.sourceId(snapshot);`
pub fn sourceId(item: *const @This(), snapshot: *const AgentThreadSnapshot) []const u8 {
    return snapshot.metadata_storage[item.source_offset..][0..item.source_len];
}

/// The provider item ID is unique only within this turn.
/// Example: `const turn = item.sourceTurn(snapshot);`
pub fn sourceTurn(item: *const @This(), snapshot: *const AgentThreadSnapshot) []const u8 {
    return snapshot.metadata_storage[item.source_turn_offset..][0..item.source_turn_len];
}

/// Example: `drawText(item.text(snapshot));`
pub fn text(item: *const @This(), snapshot: *const AgentThreadSnapshot) []const u8 {
    return snapshot.text_storage[item.text_offset..][0..item.text_len];
}

/// Example: `drawTitle(item.title(snapshot));`
pub fn title(item: *const @This(), snapshot: *const AgentThreadSnapshot) []const u8 {
    return snapshot.metadata_storage[item.title_offset..][0..item.title_len];
}

/// Example: `drawDetails(item.detail(snapshot));`
pub fn detail(item: *const @This(), snapshot: *const AgentThreadSnapshot) []const u8 {
    return snapshot.metadata_storage[item.detail_offset..][0..item.detail_len];
}

/// Returns the provider identity represented by this activity, such as a child thread.
/// Example: `drawThreadId(item.reference(snapshot));`
pub fn reference(item: *const @This(), snapshot: *const AgentThreadSnapshot) []const u8 {
    return snapshot.metadata_storage[item.reference_offset..][0..item.reference_len];
}

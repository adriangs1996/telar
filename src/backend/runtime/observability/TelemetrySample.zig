const core = @import("telar-core");
const std = @import("std");
const RuntimeMetrics = @import("RuntimeMetrics.zig");
const ClientSample = @import("ClientSample.zig");
const PaneStore = @import("../../pane/PaneStore.zig");
const Service = @import("../../history/Service.zig");
const Sample = @This();

io: std.Io,
metrics: *const RuntimeMetrics,
clients: ClientSample = .{},
workspace_count: usize = 0,
tab_count: usize = 0,
panes: *const PaneStore,
history_service: *const Service,
proxy: ProxySample = .{},
heap: *const core.Heap,

const ProxySample = struct {
    active: bool = false,
    active_connections: u32 = 0,
    event_queue_depth: u64 = 0,
    event_queue_high_water: u64 = 0,
    dropped_events: u64 = 0,
    rejected_connections: u64 = 0,
    invalid_authorization_rejections: u64 = 0,
    unknown_credential_rejections: u64 = 0,
    connection_limit_drops: u64 = 0,
    h2_decode_failures: u64 = 0,
    passthrough_connections: u64 = 0,
    upstream_connect_failures: u64 = 0,
    tls_context_failures: u64 = 0,
    tls_upstream_handshake_failures: u64 = 0,
    tls_downstream_handshake_failures: u64 = 0,
    tls_mint_failures: u64 = 0,
    claude_inference_requests: u64 = 0,
    claude_sse_payload_fragments: u64 = 0,
    claude_turn_completions: u64 = 0,
    claude_successful_responses: u64 = 0,
    claude_failure_observations: u64 = 0,
    capture_started: u64 = 0,
    capture_truncated: u64 = 0,
    capture_skipped_quota: u64 = 0,
    capture_dropped_queue: u64 = 0,
    capture_decode_failed: u64 = 0,
    capture_queue_depth: u64 = 0,
    capture_queue_high_water: u64 = 0,
};

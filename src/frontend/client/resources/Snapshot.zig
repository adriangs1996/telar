const TabIdType = @import("telar-core").TabId;
const PaneIdType = @import("telar-core").PaneId;
const SnapshotType = @import("telar-client").OutboxSnapshot;
const HostCapabilitiesType = @import("telar-client").HostCapabilities;
const SupportType = @import("telar-client").Support;
const capabilities_module = @import("../../graphics/capabilities.zig");
const TimingType = @import("telar-core").Timing;
const CoreSnapshotSnapshot = @import("telar-core").SnapshotSnapshot;
const Snapshot = @This();

theme_name: []const u8,
icon_theme_name: []const u8,
active_tab: TabIdType,
tab_count: usize,
focused_pane: PaneIdType,
pane_count: usize,
pending_updates: usize,
draw_pending: bool,
media_pending: bool,
outbox: SnapshotType,
capabilities: HostCapabilitiesType,
zlib_support: SupportType = .unknown,
sidebar_rendering: capabilities_module.ResolvedSidebarRendering,
lua_used: usize,
lua_limit: usize,
kitty_store_bytes: usize,
toast_cache_bytes: usize,
sidebar_cache_bytes: usize,
icon_cache_bytes: usize,
modal_cache_bytes: usize,
pill_cache_bytes: usize = 0,
attachment_cache_bytes: usize,
screen_bytes: usize,
shared_expiries: u8,
shared_retire_latency: TimingType,
heap: CoreSnapshotSnapshot,

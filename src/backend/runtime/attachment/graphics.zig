//! Per-client synchronization state for one pane's Kitty graphics projection.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../../pane/root.zig");

pub const Pane = pane_mod.Pane;

const shared_transfer = pane_mod.shared_transfer;

pub const shared_memory_supported = shared_transfer.shared_memory_supported;
pub const initSharedFreezeNonce = shared_transfer.initSharedFreezeNonce;
pub const freezeSharedPixels = shared_transfer.freezeSharedPixels;

pub const SnapshotState = enum { begin_pending, open, idle };

pub const Sync = @import("GraphicsSync.zig");

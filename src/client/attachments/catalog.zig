//! Bounded attachment identity, marker state and owned sensitive PNG storage.
const std = @import("std");
const core = @import("telar-core");
const types = @import("types.zig");
pub const max_items = types.max_items;
pub const max_source_bytes = types.max_source_bytes;
pub const max_png_bytes = types.max_png_bytes;
pub const max_pixels = types.max_pixels;
pub const max_retained_bytes = types.max_retained_bytes;
pub const max_marker_navigation_steps = types.max_marker_navigation_steps;
pub const max_removal_keys = types.max_removal_keys;
pub const deletion_watch_frames = types.deletion_watch_frames;
pub const Target = types.Target;
pub const CaptureRequest = types.CaptureRequest;
pub const MarkerPolicy = types.MarkerPolicy;
pub const MarkerIdentity = types.MarkerIdentity;
pub const Capture = types.Capture;
pub const CaptureResources = types.CaptureResources;
pub const Id = types.Id;
pub const Item = types.Item;
pub const Snapshot = types.Snapshot;
pub const MarkerScreen = types.MarkerScreen;
pub const MarkerDeletion = types.MarkerDeletion;
pub const MarkerRemoval = types.MarkerRemoval;
pub const DeletionProbe = types.DeletionProbe;
pub const PendingDeletion = types.PendingDeletion;
pub const PlanItem = types.PlanItem;
pub const Plan = types.Plan;
const markers = @import("markers.zig");
const minimum_marker_width = markers.minimum_marker_width;
const MarkerPosition = markers.MarkerPosition;
pub const MarkerScan = markers.MarkerScan;
pub const planPlaceholderRemoval = markers.planPlaceholderRemoval;
pub const planPathRemoval = markers.planPathRemoval;
pub const pathTouchesCursor = markers.pathTouchesCursor;
pub const markerCursorTouches = markers.markerCursorTouches;
const pathScreen = markers.pathScreen;
const findMarker = markers.findMarker;
pub const markerPresent = markers.markerPresent;
const MarkerBoundary = markers.MarkerBoundary;
pub const markerTouchesCursor = markers.markerTouchesCursor;
const parseMarker = markers.parseMarker;
const MarkerTail = markers.MarkerTail;
const parseMarkerTail = markers.parseMarkerTail;
const cellAt = markers.cellAt;
const cellsMatch = markers.cellsMatch;
const cellBlank = markers.cellBlank;
const rowBlankFrom = markers.rowBlankFrom;
const firstInkOnRow = markers.firstInkOnRow;
const markerWidthAt = markers.markerWidthAt;
pub const promptContinuesAtCursor = markers.promptContinuesAtCursor;
const editorCursor = markers.editorCursor;
const atomicSteps = markers.atomicSteps;

pub const path_marker = @import("path_marker.zig");

const Io = std.Io;
const schema = core.schema;
pub const ui = core.ui;

pub fn optionalTargetEql(a: ?Target, b: ?Target) bool {
    if (a == null or b == null) {
        return a == null and b == null;
    }
    return std.meta.eql(a.?, b.?);
}

pub const Catalog = @import("GenericCatalog.zig").Type;

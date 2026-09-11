const CopySelectionType = @import("telar-core").CopySelection;
const copy_mode_module = @import("../../input/copy_mode.zig");
const TargetType = @import("../../links/LinkTarget.zig");
const PaneViewportEffectsType = @import("../panes/PaneViewportEffects.zig");
const CopyModeEffects = @This();

context: *anyopaque,
copy: *const fn (*anyopaque, CopySelectionType) anyerror!void,
open_search: *const fn (*anyopaque, copy_mode_module.Direction) anyerror!void,
open_link: *const fn (*anyopaque, TargetType) anyerror!void,
viewport: PaneViewportEffectsType,

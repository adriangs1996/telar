const core = @import("telar-core");
const client = @import("telar-client");
const SidebarFocusType = @import("../../graphics/SidebarFocus.zig");
const SidebarProviderPlacementType = @import("../../graphics/SidebarProviderPlacement.zig");
const PlanType = @import("../../ui/Plan.zig");
const PresentationPlan = @import("../../presentation/Plan.zig");
const GraphicsPlan = @This();

toast_area: core.Rect = .{},
sidebar_area: core.Rect = .{},
focused_card: ?SidebarFocusType = null,
provider_marks: [core.max_agent_snapshot_entries]SidebarProviderPlacementType = undefined,
provider_mark_count: u8 = 0,
icons: PlanType = .{},
attachments: client.Plan = .{},
modal_area: core.Rect = .{},
pill_labels: PresentationPlan = .{},

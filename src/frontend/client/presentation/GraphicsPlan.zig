const RectType = @import("telar-core").Rect;
const SidebarFocusType = @import("../../graphics/SidebarFocus.zig");
const max_agent_snapshot_entries = @import("telar-core").max_agent_snapshot_entries;
const SidebarProviderPlacementType = @import("../../graphics/SidebarProviderPlacement.zig");
const PlanType = @import("../../ui/Plan.zig");
const ClientPlan = @import("telar-client").Plan;
const PresentationPlan = @import("../../presentation/Plan.zig");
const GraphicsPlan = @This();

toast_area: RectType = .{},
sidebar_area: RectType = .{},
focused_card: ?SidebarFocusType = null,
provider_marks: [max_agent_snapshot_entries]SidebarProviderPlacementType = undefined,
provider_mark_count: u8 = 0,
icons: PlanType = .{},
attachments: ClientPlan = .{},
modal_area: RectType = .{},
pill_labels: PresentationPlan = .{},

//! Decodes and dispatches one client request through application capabilities.

const GenericAcknowledgeAgentController = @import("../entrypoints/requests/GenericAcknowledgeAgentController.zig").Type;
const AcknowledgeAgentHandlerType = @import("commands/AcknowledgeAgentHandler.zig");
const GenericQueryAgentsController = @import("../entrypoints/requests/GenericQueryAgentsController.zig").Type;
const Delivery = @import("../delivery/Delivery.zig");
const GenericSendPaneTextController = @import("../entrypoints/requests/GenericSendPaneTextController.zig").Type;
const SendPaneTextHandlerType = @import("commands/SendPaneTextHandler.zig");
const GenericReportAgentSessionController = @import("../entrypoints/requests/GenericReportAgentSessionController.zig").Type;
const ReportAgentSessionHandlerType = @import("commands/ReportAgentSessionHandler.zig");
const GenericReportAgentController = @import("../entrypoints/requests/GenericReportAgentController.zig").Type;
const ReportAgentHandlerType = @import("commands/ReportAgentHandler.zig");
const GenericReportAgentCommandController = @import("../entrypoints/requests/GenericReportAgentCommandController.zig").Type;
const ReportAgentCommandHandlerType = @import("commands/ReportAgentCommandHandler.zig");
const GenericReportAgentTitleController = @import("../entrypoints/requests/GenericReportAgentTitleController.zig").Type;
const ReportAgentTitleHandlerType = @import("commands/ReportAgentTitleHandler.zig");
const GenericCopySelectionController = @import("../entrypoints/requests/GenericCopySelectionController.zig").Type;
const CopySelectionHandlerType = @import("commands/CopySelectionHandler.zig");
const GenericFrameAckController = @import("../entrypoints/requests/GenericFrameAckController.zig").Type;
const FrameAckHandlerType = @import("commands/FrameAckHandler.zig");
const GenericGraphicsConfigurationController = @import("../entrypoints/requests/GenericGraphicsConfigurationController.zig").Type;
const ConfigureGraphicsHandlerType = @import("commands/ConfigureGraphicsHandler.zig");
const GenericGraphicsCreditController = @import("../entrypoints/requests/GenericGraphicsCreditController.zig").Type;
const ReturnGraphicsCreditHandlerType = @import("commands/ReturnGraphicsCreditHandler.zig");
const GenericPaneInputController = @import("../entrypoints/requests/GenericPaneInputController.zig").Type;
const PaneInputHandlerType = @import("commands/PaneInputHandler.zig");
const GenericPaneResizeController = @import("../entrypoints/requests/GenericPaneResizeController.zig").Type;
const PaneResizeHandlerType = @import("commands/PaneResizeHandler.zig");
const GenericPaneViewportController = @import("../entrypoints/requests/GenericPaneViewportController.zig").Type;
const SetPaneViewportHandlerType = @import("commands/SetPaneViewportHandler.zig");
const GenericRequestGraphicsSnapshotController = @import("../entrypoints/requests/GenericRequestGraphicsSnapshotController.zig").Type;
const RequestGraphicsSnapshotHandlerType = @import("commands/RequestGraphicsSnapshotHandler.zig");
const GenericRequestSnapshotController = @import("../entrypoints/requests/GenericRequestSnapshotController.zig").Type;
const RequestCellSnapshotHandlerType = @import("commands/RequestCellSnapshotHandler.zig");
const GenericRuntimeStateController = @import("../entrypoints/requests/GenericRuntimeStateController.zig").Type;
const std = @import("std");

pub const AcknowledgeAgentController = GenericAcknowledgeAgentController(*AcknowledgeAgentHandlerType);
pub const QueryAgentsController = GenericQueryAgentsController(*Delivery);
pub const SendPaneTextController = GenericSendPaneTextController(*SendPaneTextHandlerType);
pub const ReportAgentSessionController = GenericReportAgentSessionController(*ReportAgentSessionHandlerType);
pub const ReportAgentController = GenericReportAgentController(*ReportAgentHandlerType);
pub const ReportAgentCommandController = GenericReportAgentCommandController(*ReportAgentCommandHandlerType);
pub const ReportAgentTitleController = GenericReportAgentTitleController(*ReportAgentTitleHandlerType);
pub const CopySelectionController = GenericCopySelectionController(*CopySelectionHandlerType, *Delivery);
pub const FrameAckController = GenericFrameAckController(*FrameAckHandlerType);
pub const GraphicsConfigurationController = GenericGraphicsConfigurationController(*ConfigureGraphicsHandlerType);
pub const GraphicsCreditController = GenericGraphicsCreditController(*ReturnGraphicsCreditHandlerType);
pub const PaneInputController = GenericPaneInputController(*PaneInputHandlerType);
pub const PaneResizeController = GenericPaneResizeController(*PaneResizeHandlerType);
pub const PaneViewportController = GenericPaneViewportController(*SetPaneViewportHandlerType);
pub const RequestGraphicsSnapshotController = GenericRequestGraphicsSnapshotController(*RequestGraphicsSnapshotHandlerType);
pub const RequestSnapshotController = GenericRequestSnapshotController(*RequestCellSnapshotHandlerType);
pub const RuntimeStateController = GenericRuntimeStateController(*Delivery);

test {
    std.testing.refAllDecls(@This());
}

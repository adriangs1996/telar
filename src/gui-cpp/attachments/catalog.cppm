module;
#include "catalog.hpp"

export module telar.gui.attachments.catalog;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::gui {
using telar::gui::AttachmentCapture;
using telar::gui::AttachmentCatalog;
using telar::gui::AttachmentEviction;
using telar::gui::AttachmentItem;
using telar::gui::AttachmentLimits;
using telar::gui::AttachmentMarkerDeletion;
using telar::gui::AttachmentMarkerDirection;
using telar::gui::AttachmentMarkerPlan;
using telar::gui::AttachmentMarkerPlanning;
using telar::gui::AttachmentMarkerPolicy;
using telar::gui::AttachmentMarkerReach;
using telar::gui::AttachmentMarkerRemoval;
using telar::gui::AttachmentMarkerScreen;
using telar::gui::AttachmentPathUuid;
using telar::gui::AttachmentSnapshot;
using telar::gui::AttachmentTarget;
using telar::gui::ClipboardCapture;
using telar::gui::ClipboardCaptureRequest;
using telar::gui::NumericAttachmentMarker;
using telar::gui::NumericAttachmentMarkers;
using telar::gui::PathAttachmentMarker;
using telar::gui::PathAttachmentMarkers;
using telar::gui::SensitiveBytes;
using telar::gui::attachment_uuid_bytes;
using telar::gui::eraseSensitiveBytes;
}


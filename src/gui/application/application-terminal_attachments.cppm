// Images attached to a pane's prompt as ui shows them: the types the shelf, its catalog, the
// clipboard capture and the preview hold. The shelf belongs to the window, so this partition has
// no use case of the session's; the rows the shelf takes from the panes are the workbench's
// (Session::setAttachmentReservation).
export module telar.gui.application:terminal_attachments;

import telar.gui.features.terminal.attachments;

export namespace telar::gui::application::terminal::attachments {

  using features::terminal::attachments::AttachmentCatalog;
  using features::terminal::attachments::AttachmentEviction;
  using features::terminal::attachments::AttachmentItem;
  using features::terminal::attachments::AttachmentMarkerDeletion;
  using features::terminal::attachments::AttachmentMarkerInput;
  using features::terminal::attachments::AttachmentMarkerPlan;
  using features::terminal::attachments::AttachmentMarkerReach;
  using features::terminal::attachments::AttachmentMarkerScreen;
  using features::terminal::attachments::AttachmentModalGeometry;
  using features::terminal::attachments::AttachmentPreviewBounds;
  using features::terminal::attachments::AttachmentPreviewSize;
  using features::terminal::attachments::AttachmentSnapshot;
  using features::terminal::attachments::ClipboardCaptureState;
  using features::terminal::attachments::PathAttachmentMarkers;

}

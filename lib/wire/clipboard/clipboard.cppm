module;
#include "telar_client/protocol/clipboard.hpp"

export module telar.wire.clipboard;

// Pane selections and the desktop and runtime clipboards.
//
// The owned textual header stays in this global module fragment only; importers reach
// its names through these declarations.

// The schemas are specializations of `BodySchema` and `MessageSchema` in the global
// fragment. A reduced BMI drops the fragment declarations a module never names, so naming
// both templates here keeps them reachable from importers.
export namespace telar {
  using telar::BodySchema;
  using telar::MessageSchema;
}

export namespace telar {
  using telar::CancelClipboardDesktop;
  using telar::clipboard_content_limit;
  using telar::ClipboardDesktopExecute;
  using telar::ClipboardDesktopRequest;
  using telar::ClipboardDesktopStatus;
  using telar::ClipboardRepresentation;
  using telar::ClipboardTicket;
  using telar::CompleteClipboardDesktop;
  using telar::CopySelection;
  using telar::PaneClipboard;
  using telar::PastePaneClipboard;
  using telar::ReadRuntimeClipboard;
  using telar::runtime_clipboard_chunk_bytes;
  using telar::runtime_clipboard_max_bytes;
  using telar::RuntimeClipboardChunk;
  using telar::validateClipboardContents;
}

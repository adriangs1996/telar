module;
#include "telar_client/protocol/content.hpp"

export module telar.wire.content;

// Reading and searching what a pane shows: text, rows, documents, blocks and
// scrollback.
//
// The owned textual header stays in this global module fragment only; importers reach
// its names through these declarations.

// The schemas are specializations of `MessageSchema` in the global fragment. A reduced BMI
// drops the fragment declarations a module never names, so naming the template here keeps
// them reachable from importers.
export namespace telar {
  using telar::MessageSchema;
}

export namespace telar {
  using telar::PaneBlocks;
  using telar::PaneDocument;
  using telar::PaneMatches;
  using telar::PaneRows;
  using telar::PaneScrollback;
  using telar::PaneText;
  using telar::ReadPane;
  using telar::ReadPaneRows;
  using telar::SearchPane;
  using telar::SearchPaneRows;
}

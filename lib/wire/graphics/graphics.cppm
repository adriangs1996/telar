module;
#include "telar_client/protocol/graphics.hpp"

export module telar.wire.graphics;

// Terminal graphics: images, placements and their snapshots.
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
  using telar::ConfigureGraphics;
  using telar::GraphicsCredit;
  using telar::GraphicsDeleteImage;
  using telar::GraphicsDeletePlacement;
  using telar::GraphicsImage;
  using telar::GraphicsImageChunk;
  using telar::GraphicsPlacementMessage;
  using telar::GraphicsSharedImage;
  using telar::GraphicsSnapshot;
  using telar::RequestGraphicsSnapshot;
}

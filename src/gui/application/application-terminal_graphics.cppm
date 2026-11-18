// The images in a terminal as ui draws them: the types a frame reads of each pane's images and
// keeps of their textures, and the panes paused after a limit.
export module telar.gui.application:terminal_graphics;

import std;

import :session;
import telar.gui.features.terminal.graphics;
import telar.wire.graphics;
import telar.base.ds;

export namespace telar::gui::application::terminal::graphics {

  using features::terminal::graphics::ArtworkResize;
  using features::terminal::graphics::GraphicsBudget;
  using features::terminal::graphics::GraphicsLifetime;
  using features::terminal::graphics::GraphicsPauseLimits;
  using features::terminal::graphics::GraphicsStore;
  using features::terminal::graphics::image_texture_capacity;
  using features::terminal::graphics::ImageDisplayBox;
  using features::terminal::graphics::ImageDrawBudget;
  using features::terminal::graphics::ImageGeometry;
  using features::terminal::graphics::ImagePlacementSelection;
  using features::terminal::graphics::ImageResidency;
  using features::terminal::graphics::ImageSourceRect;
  using features::terminal::graphics::ImageTextureHandle;
  using features::terminal::graphics::ImageTextureIdentity;
  using features::terminal::graphics::ImageTextureStage;
  using features::terminal::graphics::parsePlaceholder;
  using features::terminal::graphics::placeholderGeometry;
  using features::terminal::graphics::PlaceholderRun;
  using features::terminal::graphics::placementOrder;
  using features::terminal::graphics::RgbaImageView;

  // Whether pane `pane_id`'s images are paused after a limit.
  [[nodiscard]] bool paused(const Session& session, std::uint64_t pane_id) noexcept;

  // Changes whenever a pause begins, waits or ends.
  [[nodiscard]] std::uint64_t recoveryRevision(const Session& session) noexcept;

  // When the next paused pane asks the runtime again; none while none waits.
  [[nodiscard]] ds::Option<std::uint64_t> resumeDeadline(const Session& session) noexcept;

  // The paused panes whose wait ended ask the runtime for their images again.
  void resume(Session& session);

}

// What the session's routing and its other use cases reach of the images; ui never calls these.
namespace telar::gui::application::terminal::graphics {

  // Asks the runtime for all of pane `pane_id`'s images again.
  void requestSnapshot(Session& session, std::uint64_t pane_id);

  // Pane `pane_id` took the focus: a paused pane asks again at once.
  void focus(Session& session, std::uint64_t pane_id);

  // The panes the session no longer holds stop pausing.
  void forgetClosed(Session& session);

  Change receive(Session& session, const GraphicsSnapshot& message);

  Change receive(Session& session, const GraphicsImage& message);

  Change receive(Session& session, const GraphicsSharedImage& message);

  Change receive(Session& session, const GraphicsImageChunk& message);

  Change receive(Session& session, const GraphicsPlacementMessage& message);

  Change receive(Session& session, const GraphicsDeleteImage& message);

  Change receive(Session& session, const GraphicsDeletePlacement& message);

}

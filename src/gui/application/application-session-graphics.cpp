module telar.gui.application;

import std;

import telar.wire.graphics;

namespace telar::gui::application {

  Change Session::apply(const GraphicsSnapshot& message) {
    return terminal::graphics::receive(*this, message);
  }

  Change Session::apply(const GraphicsImage& message) {
    return terminal::graphics::receive(*this, message);
  }

  bool Session::supportsSharedGraphics() const noexcept {
    return link.transport.supportsSharedMemory();
  }

  Change Session::apply(const GraphicsSharedImage& message) {
    return terminal::graphics::receive(*this, message);
  }

  Change Session::apply(const GraphicsImageChunk& message) {
    return terminal::graphics::receive(*this, message);
  }

  Change Session::apply(const GraphicsPlacementMessage& message) {
    return terminal::graphics::receive(*this, message);
  }

  Change Session::apply(const GraphicsDeleteImage& message) {
    return terminal::graphics::receive(*this, message);
  }

  Change Session::apply(const GraphicsDeletePlacement& message) {
    return terminal::graphics::receive(*this, message);
  }

}

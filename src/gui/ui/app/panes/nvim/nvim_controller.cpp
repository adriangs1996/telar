#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "nvim_controller.hpp"
#include <exception>

import telar.gui.application;

namespace telar::gui::qt {

  NvimController::NvimController(tbc::holds<const Parts&, tbc::lt::a> parts, QObject* parent)
      : QObject(parent),
        store_(parts.store),
        host_(parts.host) {}

  // What a view asks of the session reaches the runtime or is reported: a view never throws
  // into Qt's event loop.
  template <typename Request>
  void NvimController::attempt(Request request) {
    try {
      request(store_.sessionMut());
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }
  }

  void NvimController::type(std::uint64_t pane_id, std::string_view keys) {
    attempt([&](GuiSession& session) {
      application::nvim::type(session, pane_id, keys);
    });
  }

  void NvimController::paste(std::uint64_t pane_id, const QString& text) {
    const auto bytes = text.toUtf8();

    attempt([&](GuiSession& session) {
      application::nvim::paste(session, pane_id, {bytes.constData(), static_cast<std::size_t>(bytes.size())});
    });
  }

  void NvimController::point(const application::nvim::NvimMouse& event) {
    attempt([&](GuiSession& session) {
      application::nvim::point(session, event);
    });
  }

  void NvimController::focus(std::uint64_t pane_id, bool focused) {
    attempt([&](GuiSession& session) {
      application::nvim::focus(session, pane_id, focused);
    });
  }

  void NvimController::resize(std::uint64_t pane_id, TerminalSize size) {
    attempt([&](GuiSession& session) {
      application::nvim::resize(session, pane_id, size);
    });
  }

  void NvimController::choose(std::uint64_t pane_id, std::uint32_t item, bool accept) {
    attempt([&](GuiSession& session) {
      application::nvim::choose(session, pane_id, item, accept);
    });
  }

  void NvimController::pick(std::uint64_t pane_id, application::nvim::NvimPickSource source) {
    attempt([&](GuiSession& session) {
      application::nvim::pick(session, pane_id, source);
    });
    // The picker changed here, not by a message of the runtime: its views are told.
    emit editorChanged(pane_id);
  }

  void NvimController::search(std::uint64_t pane_id, const QString& query) {
    const auto bytes = query.toUtf8();

    attempt([&](GuiSession& session) {
      application::nvim::search(session, pane_id, {bytes.constData(), static_cast<std::size_t>(bytes.size())});
    });
    // The picker changed here, not by a message of the runtime: its views are told.
    emit editorChanged(pane_id);
  }

  void NvimController::accept(std::uint64_t pane_id, std::size_t index, application::nvim::NvimOpenIn in) {
    attempt([&](GuiSession& session) {
      application::nvim::accept(session, pane_id, index, in);
    });
    // The picker changed here, not by a message of the runtime: its views are told.
    emit editorChanged(pane_id);
  }

  void NvimController::preview(std::uint64_t pane_id, ds::Option<std::size_t> index, application::nvim::PreviewArea area) {
    attempt([&](GuiSession& session) {
      application::nvim::preview(session, pane_id, index, area);
    });
  }

  void NvimController::list(std::uint64_t pane_id, std::span<const std::uint32_t> indices) {
    attempt([&](GuiSession& session) {
      application::nvim::list(session, pane_id, indices);
    });
    // The picker changed here, not by a message of the runtime: its views are told.
    emit editorChanged(pane_id);
  }

  void NvimController::dismiss(std::uint64_t pane_id) {
    attempt([&](GuiSession& session) {
      application::nvim::dismiss(session, pane_id);
    });
    // The picker changed here, not by a message of the runtime: its views are told.
    emit editorChanged(pane_id);
  }

  void NvimController::answer(std::uint64_t pane_id, bool accepted, std::uint32_t index, const QString& text) {
    const auto bytes = text.toUtf8();

    attempt([&](GuiSession& session) {
      application::nvim::answer(session, pane_id, accepted, index, {bytes.constData(), static_cast<std::size_t>(bytes.size())});
    });
  }

}

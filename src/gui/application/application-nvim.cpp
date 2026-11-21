module telar.gui.application;

import std;

import :access;
import telar.gui.features.nvim;
import telar.wire.nvim;
import telar.wire.pane_io;
import telar.wire.vocabulary;

namespace telar::gui::application::nvim {

  namespace feature = features::nvim;

  namespace {

    // Whether the session may send the pane's editor something: it speaks the editor's messages
    // and is attached to the pane.
    [[nodiscard]] bool reaches(const Session& session, std::uint64_t pane_id) noexcept {
      const auto* pane = findPane(session.panes, pane_id);

      return available(session) && pane != nullptr && pane->attached && !pane->exited && feature::find(session.nvim, pane_id) != nullptr;
    }

    // What a message did, as the window hears it: a frame that ended is drawn, and one the
    // editor cannot follow asks the runtime for its screen whole, once.
    Change settle(Session& session, std::uint64_t pane_id, feature::Received received) {
      switch (received) {
      case feature::Received::presented:
        // The runtime sends the next frame once it knows this one was applied.
        if (const auto* shown = feature::find(session.nvim, pane_id); shown != nullptr && shown->frame != 0) {
          session.link.send(FrameAck{.pane_id = pane_id, .frame_id = shown->frame});
        }

        Access::changedPane(session) = pane_id;
        return Change::editor;
      case feature::Received::lost:
        session.link.send(RequestSnapshot{.pane_id = pane_id});
        return Change::none;
      case feature::Received::ignored:
      case feature::Received::staged:
        return Change::none;
      }

      return Change::none;
    }

  }

  bool available(const Session& session) noexcept {
    return session.ready() && session.speaks(ClientTag::create_nvim_pane);
  }

  const Editor* editor(const Session& session, std::uint64_t pane_id) noexcept {
    return feature::find(session.nvim, pane_id);
  }

  void type(Session& session, std::uint64_t pane_id, std::string_view keys) {
    if (!keys.empty() && keys.size() <= max_nvim_input_bytes && reaches(session, pane_id)) {
      session.link.send(NvimInput{.pane_id = pane_id, .keys = {reinterpret_cast<const Byte*>(keys.data()), keys.size()}}); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the wire carries the text as bytes
    }
  }

  void paste(Session& session, std::uint64_t pane_id, std::string_view text) {
    if (!text.empty() && text.size() <= max_nvim_paste_bytes && reaches(session, pane_id)) {
      session.link.send(NvimPaste{.pane_id = pane_id, .text = {reinterpret_cast<const Byte*>(text.data()), text.size()}}); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the wire carries the text as bytes
    }
  }

  void point(Session& session, const NvimMouse& event) {
    if (reaches(session, event.pane_id)) {
      session.link.send(event);
    }
  }

  void focus(Session& session, std::uint64_t pane_id, bool focused) {
    if (reaches(session, pane_id)) {
      session.link.send(NvimFocus{.pane_id = pane_id, .focused = focused});
    }
  }

  void resize(Session& session, std::uint64_t pane_id, TerminalSize size) {
    auto* pane = findPaneMut(session.panes, pane_id);
    if (pane == nullptr || !reaches(session, pane_id) || pane->size == size) {
      return;
    }

    session.link.send(PaneResize{.pane_id = pane_id, .size = size});
    pane->size = size;
  }

  void answer(Session& session, std::uint64_t pane_id, bool accepted, std::uint32_t index, std::string_view text) {
    if (!reaches(session, pane_id) || text.size() > max_nvim_line_bytes) {
      return;
    }

    if (const auto reply = feature::answer(session.nvim, pane_id, accepted, index, text)) {
      session.link.send(*reply);
      Access::changedPane(session) = pane_id;
    }
  }

  void show(Session& session, std::uint64_t pane_id, const Place& place) {
    if (!place.path.empty() && place.path.size() <= max_nvim_path_bytes && reaches(session, pane_id)) {
      session.link.send(NvimOpen{.pane_id = pane_id, .path = place.path, .line = place.line, .column = place.column, .in = place.in});
    }
  }

  std::uint64_t beside(const Session& session, std::uint64_t pane_id) noexcept {
    const auto* source = findPane(session.panes, pane_id);
    if (source == nullptr) {
      return 0;
    }

    for (const auto& pane : session.panes) {
      if (pane->location.tab_id == source->location.tab_id && pane->location.workspace.id == source->location.workspace.id && reaches(session, pane->id)) {
        return pane->id;
      }
    }

    return 0;
  }

  void navigate(Session& session, std::uint64_t pane_id, PaneDirection direction) {
    if (reaches(session, pane_id) && session.speaks(ClientTag::nvim_navigate)) {
      session.link.send(NvimNavigate{.pane_id = pane_id, .direction = direction});
    }
  }

  void choose(Session& session, std::uint64_t pane_id, std::uint32_t item, bool accept) {
    if (reaches(session, pane_id) && session.speaks(ClientTag::nvim_menu_select)) {
      session.link.send(NvimMenuSelect{.pane_id = pane_id, .item = item, .accept = accept});
    }
  }

  Change receive(Session& session, const NvimNavigated& message) {
    const auto* focused = focusedPane(session.panes, session.tabs, session.active_tab);
    if (focused == nullptr || focused->id != message.pane_id) {
      return Change::none;
    }

    // The editor had no window on that side: the pane there takes the focus.
    workbench::focusToward(session, message.direction);
    return Change::model;
  }

  Change receive(Session& session, const PaneKindNotice& message) {
    feature::announce(session.nvim, message);
    return Change::none;
  }

  Change receive(Session& session, const NvimGrid& message) {
    return settle(session, message.pane_id, feature::receive(session.nvim, message));
  }

  Change receive(Session& session, const NvimFrame& message) {
    return settle(session, message.pane_id, feature::receive(session.nvim, message));
  }

  Change receive(Session& session, const NvimCmdline& message) {
    return settle(session, message.pane_id, feature::receive(session.nvim, message));
  }

  Change receive(Session& session, const NvimPopupMenu& message) {
    return settle(session, message.pane_id, feature::receive(session.nvim, message));
  }

  Change receive(Session& session, const NvimMessageList& message) {
    return settle(session, message.pane_id, feature::receive(session.nvim, message));
  }

  Change receive(Session& session, const NvimTabLine& message) {
    return settle(session, message.pane_id, feature::receive(session.nvim, message));
  }

  Change receive(Session& session, const NvimPrompt& message) {
    const auto received = feature::receive(session.nvim, message);
    if (received == feature::Received::presented) {
      Access::changedPane(session) = message.pane_id;
      return Change::editor;
    }

    return Change::none;
  }

}

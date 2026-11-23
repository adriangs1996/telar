module telar.gui.application;

import std;

import :access;
import telar.gui.features.nvim;
import telar.gui.features.terminal.links;
import telar.base.text;
import telar.base.memory.allocators;
import telar.gui.foundation.system;
import telar.wire.editor;
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

  bool edit(Session& session, std::uint64_t pane_id, const Place& place) {
    if (place.path.empty() || place.path.size() > max_nvim_path_bytes || !available(session)) {
      return false;
    }

    if (const auto shown = beside(session, pane_id); shown != 0) {
      show(session, shown, place);
      workbench::focusPane(session, shown);
      return true;
    }

    const ds::Array<std::string_view, 1> files{place.path};

    return workbench::splitEditor(session, ClientLayoutAxis::horizontal, files.view(), {.line = place.line, .column = place.column});
  }

  namespace {

    // The queries shorter than this ask for no text: every line of every file would match.
    constexpr std::size_t shortest_text_query = 2;
    constexpr std::uint16_t path_limit = FindPaths::maximum_limit;
    constexpr std::uint16_t text_limit = 100;

    // The file a picker's entry names, as Neovim opens it: under the picker's directory unless
    // it says where it is itself.
    void locate(ds::String<Memory>& path, const Picker& picker, const PickMatch& match) {
      const auto name = match.path.of(std::string_view{picker.text.data(), picker.text.size()});

      path.clear();
      if (!name.starts_with('/') && !name.starts_with('~')) {
        path.append(picker.root.view());
        if (!picker.root.view().ends_with('/')) {
          path.append("/");
        }
      }

      path.append(name);
    }

    Change shown(Session& session, std::uint64_t pane_id) {
      Access::changedPane(session) = pane_id;
      return Change::editor;
    }

  }

  bool editCommand(Session& session, std::span<const std::string_view> arguments) {
    const auto* focused = focusedPane(session.panes, session.tabs, session.active_tab);
    if (focused == nullptr || arguments.size() != 3 || arguments[0] != "telar" || arguments[1] != "edit" || arguments[2].empty()) {
      return false;
    }

    // `FILE:LINE` names a line, when what follows the last colon is a number.
    auto file = arguments[2];
    std::uint32_t line = 0;

    if (const auto colon = file.rfind(':'); colon != std::string_view::npos && colon > 0) {
      if (const auto number = runtime::parseExact<std::uint32_t>(file.substr(colon + 1))) {
        line = *number;
        file = file.substr(0, colon);
      }
    }

    // Kept before the session changes: the pane's directory is the session's.
    const auto pane_id = focused->id;
    ds::String<Memory> path{session.memory};

    if (!file.starts_with('/')) {
      path.append(std::string_view{focused->cwd});
      path.append("/");
    }

    path.append(file);
    return path.view().starts_with('/') && edit(session, pane_id, {.path = path.view(), .line = line});
  }

  bool find(Session& session, NvimPickSource source) {
    const auto* focused = focusedPane(session.panes, session.tabs, session.active_tab);
    if (focused == nullptr) {
      return false;
    }

    // The focused pane when it is an editor: a tab may have more than one.
    const auto focused_id = focused->id;
    const auto editor = reaches(session, focused_id) ? focused_id : beside(session, focused_id);
    if (editor == 0) {
      return false;
    }

    workbench::focusPane(session, editor);
    pick(session, editor, source);
    return true;
  }

  void pick(Session& session, std::uint64_t pane_id, NvimPickSource source) {
    const auto* pane = findPane(session.panes, pane_id);
    if (pane == nullptr || !reaches(session, pane_id) || !session.speaks(ClientTag::find_text) || !std::string_view{pane->cwd}.starts_with('/')) {
      return;
    }

    if (feature::pick(session.nvim, pane_id, source, pane->cwd)) {
      Access::changedPane(session) = pane_id;
      search(session, pane_id, {});
    }
  }

  void search(Session& session, std::uint64_t pane_id, std::string_view query) {
    const auto* editor = feature::find(session.nvim, pane_id);
    if (editor == nullptr || !editor->picker.open || !reaches(session, pane_id)) {
      return;
    }

    const auto source = editor->picker.source;
    const bool searches_text = source == NvimPickSource::text;

    Access::changedPane(session) = pane_id;
    if (query.size() > (searches_text ? FindText::maximum_query_bytes : FindPaths::maximum_query_bytes) || (searches_text && query.size() < shortest_text_query)) {
      static_cast<void>(feature::ask(session.nvim, pane_id, query.substr(0, FindText::maximum_query_bytes), 0));
      return;
    }

    const auto request = session.link.nextRequest();

    static_cast<void>(feature::ask(session.nvim, pane_id, query, request));

    // Read after the picker took the query: the messages view what it holds.
    const auto& picker = feature::find(session.nvim, pane_id)->picker;

    switch (source) {
    case NvimPickSource::files:
      session.link.send(FindPaths{.request_id = request, .root = picker.root.view(), .query = picker.query.view(), .kind = PathKindFilter::files, .limit = path_limit, .refresh = picker.fresh});
      feature::refreshed(session.nvim, pane_id);
      break;
    case NvimPickSource::text:
      session.link.send(FindText{.request_id = request, .root = picker.root.view(), .query = picker.query.view(), .limit = text_limit});
      break;
    case NvimPickSource::buffers:
      session.link.send(NvimBuffers{.request_id = request, .pane_id = pane_id, .query = picker.query.view(), .limit = path_limit});
      break;
    }
  }

  void accept(Session& session, std::uint64_t pane_id, Choice choice) {
    const auto* editor = feature::find(session.nvim, pane_id);
    if (editor == nullptr || !editor->picker.open || choice.index >= editor->picker.matches.size()) {
      return;
    }

    const auto& match = editor->picker.matches[choice.index];
    ds::String<Memory> path{editor->memory};

    locate(path, editor->picker, match);
    show(session, pane_id, {.path = path.view(), .line = match.line, .column = match.column, .in = choice.where});
    dismiss(session, pane_id);
  }

  void preview(Session& session, std::uint64_t pane_id, ds::Option<std::size_t> index, PreviewArea area) {
    const auto* editor = feature::find(session.nvim, pane_id);
    if (editor == nullptr || !reaches(session, pane_id) || !session.speaks(ClientTag::nvim_preview)) {
      return;
    }

    if (!index || !editor->picker.open || *index >= editor->picker.matches.size() || area.columns == 0 || area.rows == 0) {
      session.link.send(NvimPreview{.pane_id = pane_id});
      return;
    }

    const auto& match = editor->picker.matches[*index];
    ds::String<Memory> path{editor->memory};

    locate(path, editor->picker, match);
    if (path.size() <= max_nvim_path_bytes) {
      session.link.send(NvimPreview{.pane_id = pane_id, .path = path.view(), .line = match.line, .row = area.row, .column = area.column, .columns = area.columns, .rows = area.rows});
    }
  }

  void list(Session& session, std::uint64_t pane_id, std::span<const std::uint32_t> indices) {
    const auto* editor = feature::find(session.nvim, pane_id);
    if (editor == nullptr || !editor->picker.open || indices.empty() || indices.size() > NvimList::maximum_places || !reaches(session, pane_id)) {
      return;
    }

    const auto& picker = editor->picker;
    const std::string_view text{picker.text.data(), picker.text.size()};
    // The session's own memory: the editor is only read while these grow.
    ds::Vec<ds::String<Memory>, Memory> paths{session.memory};
    ds::Vec<TextMatch, Memory> places{session.memory};

    // Every path is made before any place views one: the places are views of them.
    paths.reserve(indices.size());
    for (const auto index : indices) {
      if (index < picker.matches.size()) {
        locate(paths.emplace(session.memory), picker, picker.matches[index]);
      }
    }

    places.reserve(paths.size());
    for (std::size_t made = 0, at = 0; at < indices.size(); ++at) {
      if (indices[at] >= picker.matches.size()) {
        continue;
      }

      const auto& match = picker.matches[indices[at]];

      // A place without a line is the file's first.
      places.push({.path = paths[made++].view(), .line = std::max<std::uint32_t>(match.line, 1), .column = std::max<std::uint32_t>(match.column, 1), .text = match.text.of(text)});
    }

    if (!places.empty()) {
      session.link.send(NvimList{.pane_id = pane_id, .places = places.view()});
      dismiss(session, pane_id);
    }
  }

  void dismiss(Session& session, std::uint64_t pane_id) {
    if (feature::dismiss(session.nvim, pane_id)) {
      Access::changedPane(session) = pane_id;
      if (reaches(session, pane_id) && session.speaks(ClientTag::nvim_preview)) {
        session.link.send(NvimPreview{.pane_id = pane_id});
      }
    }
  }

  void dismissMessage(Session& session, std::uint64_t pane_id, std::uint64_t key) {
    if (feature::dismissMessage(session.nvim, pane_id, key)) {
      Access::changedPane(session) = pane_id;
    }
  }

  ConfigurationBrought bringConfiguration(Session& session, std::string_view directory) {
    if (!session.ready() || !session.speaks(ClientTag::nvim_configuration)) {
      return ConfigurationBrought::refused;
    }

    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;
    ds::Vec<FileTreeFile, Memory> tree{memory};
    // What a message carries besides the files' bytes: each file's path and the lengths of both.
    constexpr std::size_t message_room = 64;
    constexpr std::size_t file_room = 6;
    FileTreeRead read = FileTreeRead::absent;

    try {
      read = readFileTree(memory, directory, {.files = NvimConfiguration::maximum_files, .bytes = max_payload_size - message_room, .depth = 32}, tree);
    } catch (const std::exception& error) {
      Access::error(session).assign("The editor's configuration could not be read, so it was not brought to the machine: ");
      Access::error(session).append(error.what());
      return ConfigurationBrought::unreadable;
    }

    if (read == FileTreeRead::absent) {
      return ConfigurationBrought::absent;
    }

    ds::Vec<NvimConfigurationFile, Memory> files{memory};
    std::size_t size = message_room;

    files.reserve(tree.size());
    for (const auto& file : tree) {
      files.push({.path = file.path.view(), .content = file.content.view()});
      size += file_room + file.path.size() + file.content.size();
    }

    if (read == FileTreeRead::too_large || size > max_payload_size) {
      Access::error(session).assign("The editor's configuration is larger than a machine takes: it was not brought there");
      return ConfigurationBrought::too_large;
    }

    return session.link.ask(NvimConfiguration{.files = files.view()}) ? ConfigurationBrought::sent : ConfigurationBrought::refused;
  }

  Change receive(Session& session, const NvimLink& message) {
    return feature::link(session.nvim, message.pane_id, message.uri) ? shown(session, message.pane_id) : Change::none;
  }

  ds::Option<features::terminal::links::LinkTarget> takeLink(Session& session, std::uint64_t pane_id) {
    const auto* editor = feature::find(session.nvim, pane_id);
    if (editor == nullptr || editor->link.empty()) {
      return ds::none;
    }

    const auto target = features::terminal::links::LinkTarget::fromUri(editor->link.view());

    static_cast<void>(feature::link(session.nvim, pane_id, {}));
    return target;
  }

  Change receive(Session& session, const NvimPick& message) {
    pick(session, message.pane_id, message.source);

    const auto* editor = feature::find(session.nvim, message.pane_id);
    const bool opened = editor != nullptr && editor->picker.open;

    return opened ? shown(session, message.pane_id) : Change::none;
  }

  Change receive(Session& session, const TextResults& message) {
    const auto pane_id = feature::receive(session.nvim, message);

    return pane_id == 0 ? Change::none : shown(session, pane_id);
  }

  ds::Option<Change> receive(Session& session, const PathResults& message) {
    const auto pane_id = feature::receive(session.nvim, message);
    if (pane_id == 0) {
      return ds::none;
    }

    return shown(session, pane_id);
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

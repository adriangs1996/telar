module telar.gui.application;

import std;
import telar.gui.foundation.terminal;
import telar.render.document;
import telar.gui.foundation.core;
import telar.gui.features.prompt;
import telar.gui.features.terminal.graphics;
import telar.config.client;
import telar.config.runtime;
import telar.base.text;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.editor;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.shell.syntax;
import telar.base.ds;

namespace telar::gui::application {

  void Session::input(std::uint64_t pane_id, std::string_view bytes, PaneInputSource source) {
    auto* pane = findPaneMut(pane_id);
    if (pane == nullptr || !pane->attached || pane->exited || bytes.empty()) {
      return;
    }

    // A key typed into a secret prompt shows as one more dot in the prompt's line.
    if (source == PaneInputSource::keyboard && prompt::surface(*this, pane_id) == features::prompt::Surface::secret) {
      prompt::typeSecret(*this, pane_id, bytes.front());
    }

    if (source == PaneInputSource::keyboard || source == PaneInputSource::key_release) {
      static_cast<void>(features::terminal::copy_mode::clearPointer(copy_mode));
      if (source != PaneInputSource::key_release) {
        followLiveEnd(*pane);
      }
    }

    auto pending_bytes = byteView(bytes);

    while (!pending_bytes.empty()) {
      const auto count = std::min(pending_bytes.size(), input_chunk_size);

      link.send(PaneInput{.pane_id = pane_id, .bytes = pending_bytes.first(count)});
      if (source != PaneInputSource::terminal_report && pending_bytes.size() == bytes.size()) {
        notePaneInput(*pane);
      }

      pending_bytes = pending_bytes.subspan(count);
    }
  }

  void Session::runCommand(std::uint64_t pane_id, std::string_view text) {
    auto* pane = findPaneMut(pane_id);
    if (pane == nullptr || !pane->attached || pane->exited || text.empty()) {
      return;
    }

    if (!speaks(ClientTag::pane_command)) {
      pasteBytes(pane_id, text);
      input(pane_id, "\r");
      return;
    }

    static_cast<void>(features::terminal::copy_mode::clearPointer(copy_mode));
    followLiveEnd(*pane);
    link.send(PaneCommand{.pane_id = pane_id, .text = byteView(text)});
    notePaneInput(*pane);
  }

  void Session::followLiveEnd(Pane<Memory>& pane) {
    const auto bottom = copyGrid(pane.screen).maximumOffset();
    if (pane.screen.scroll().offset != bottom) {
      ++view_version.viewport;
      ++pane.viewport_requests;
      pane.screen.setViewport(bottom);
      link.send(SetPaneViewport{.pane_id = pane.id, .offset = follow_output});
    }
  }

  void Session::notePaneInput(const Pane<Memory>& pane) {
    effects_.notePaneInput({.pane_id = pane.id, .frame_id = pane.screen.frameId(), .attached = pane.attached, .attachment_generation = pane.attachment_generation, .graphics_revision = pane.graphics.revision()});
  }

  bool Session::readsRows() const noexcept {
    return speaks(ClientTag::read_pane_rows) && ready_;
  }

  bool Session::readsTheme() const noexcept {
    return speaks(ClientTag::read_pane_theme) && ready_;
  }

  void Session::requestRows(std::uint64_t pane_id, std::uint64_t first, std::uint64_t last) {
    auto* pane = findPaneMut(pane_id);
    if (pane == nullptr || !pane->attached || !readsRows() || pane->scrollback_generation == 0 || last < first) {
      return;
    }

    const auto screen_first = pane->scrollback_trimmed + pane->screen.cellsOffset();
    const auto screen_last = screen_first + pane->screen.rows();
    auto from = first;

    while (!pane->rows.full()) {
      const auto missing = pane->rows.missing(from, last);
      if (!missing) {
        return;
      }

      // Rows on the screen come in its frames.
      if (*missing >= screen_first && *missing < screen_last) {
        from = screen_last;
        continue;
      }

      const auto count = static_cast<std::uint16_t>(std::min<std::uint64_t>(RowCache<Memory>::request_rows, last - *missing + 1));
      const auto request_id = link.nextRequest();

      link.send(ReadPaneRows{.request_id = request_id, .pane_id = pane_id, .from = *missing, .count = count});
      pane->rows.ask(request_id, *missing, count);
      from = *missing + count;
    }
  }

  std::uint64_t Session::takeDroppedRows(std::uint64_t pane_id) noexcept {
    auto* pane = findPaneMut(pane_id);

    return pane == nullptr ? 0 : std::exchange(pane->scrollback_dropped, 0);
  }

  void Session::resize(std::uint64_t pane_id, TerminalSize size) {
    resizePane(panes, link, view_version, pane_id, size);
  }

  void Session::resizePane(Panes& panes, Link& link, ViewVersion& view_version, std::uint64_t pane_id, TerminalSize size) {
    auto* pane = application::findPaneMut(panes, pane_id);
    if (pane == nullptr || pane->size == size) {
      return;
    }

    if (pane->attached) {
      link.send(PaneResize{.pane_id = pane_id, .size = size});
    }

    pane->size = size;
    ++view_version.viewport;
  }

  void Session::presented(std::uint64_t pane_id, std::uint64_t frame_id) {
    auto* pane = findPaneMut(pane_id);
    if (ready_ && pane != nullptr && pane->attached && frame_id > pane->acknowledged_frame && frame_id <= pane->screen.frameId()) {
      link.send(FrameAck{.pane_id = pane_id, .frame_id = frame_id});
      pane->acknowledged_frame = frame_id;
    }
  }

  void Session::scroll(PaneScrollDelta delta) {
    auto* pane = findPaneMut(delta.pane_id);
    if (pane == nullptr || !pane->attached || features::terminal::copy_mode::view(copy_mode).active()) {
      return;
    }

    const auto& viewport = pane->screen.scroll();
    const auto maximum = std::max<std::int64_t>(0, static_cast<std::int64_t>(viewport.total_rows) - pane->screen.rows());
    const auto offset = static_cast<std::int64_t>(viewport.offset);
    const auto bounded_delta = std::clamp(delta.rows, offset - maximum, offset);
    const auto requested = static_cast<std::uint32_t>(offset - bounded_delta);
    if (requested == viewport.offset) {
      return;
    }

    // The bottom as this replica knows it may be behind the runtime's: ask to follow instead.
    ++pane->viewport_requests;
    link.send(SetPaneViewport{.pane_id = delta.pane_id, .offset = std::cmp_equal(requested, maximum) ? follow_output : requested});
    pane->screen.setViewport(requested);
    ++view_version.viewport;
  }

  bool Session::measureInline(InlineDocumentAt document, std::uint32_t rows) {
    const auto [pane_id, id] = document;
    auto* pane = findPaneMut(pane_id);
    if (pane == nullptr) {
      return false;
    }

    using Inline = Pane<Memory>::InlineDocument;
    const auto documents = pane->inline_documents.viewMut();
    const auto found = std::ranges::find(documents, id, &Inline::id);
    if (found == documents.end() || found->view_rows == rows) {
      return false;
    }

    found->view_rows = rows;
    ++pane->inline_version;
    refreshFolds(*pane);
    return true;
  }

  Change Session::apply(const PaneFrame& message) {
    auto* pane = findPaneMut(message.pane_id);
    if (pane == nullptr || !pane->attached) {
      return Change::none;
    }

    const auto previous_offset = pane->screen.scroll().offset;
    const auto outcome = pane->screen.apply(message);
    if (outcome == FrameApplication::needs_snapshot && !pane->snapshot_requested) {
      // Marked once the request left: one the transport refused is asked again with the next frame.
      link.send(RequestSnapshot{.pane_id = message.pane_id, .known_frame_id = pane->screen.frameId()});
      pane->snapshot_requested = true;
    }

    if (outcome == FrameApplication::applied) {
      if (const auto& copy = features::terminal::copy_mode::view(copy_mode).state(); copy && copy->pane_id == pane->id) {
        features::terminal::copy_mode::follow(copy_mode, previous_offset, copyGrid(pane->screen));
      }

      features::prompt::output(prompt_lines, pane->id, [this] {
        return now_();
      });

      pane->snapshot_requested = false;
      if (const auto live_prompt = livePromptRow(*pane)) {
        pane->live_prompt_row = live_prompt;
      }

      if (!pane->folded.empty()) {
        refreshFolds(*pane);
      }

      changed_pane_ = pane->id;

      return Change::terminal;
    }

    return Change::none;
  }

  Change Session::apply(const PaneTitle& message) {
    if (auto* pane = findPaneMut(message.pane_id)) {
      pane->title.assign(message.title);
      ++chrome_revision_;
    }

    return Change::model;
  }

  Change Session::apply(const PaneCwd& message) {
    if (auto* pane = findPaneMut(message.pane_id)) {
      pane->cwd.assign(message.cwd);
      ++chrome_revision_;
    }

    return Change::model;
  }

  Change Session::apply(const PaneForeground& message) {
    if (auto* pane = findPaneMut(message.pane_id)) {
      pane->foreground.assign(message.name);
    }

    // A command started or ended there: what it touched is asked of the runtime again.
    features::explorer::stir(explorer);

    for (auto& tab : tabs.viewMut()) {
      tab.getMut().observeForeground(message);
    }

    ++chrome_revision_;

    return Change::model;
  }

  Change Session::apply(const PaneClipboard& message) {
    auto text = textView(message.bytes);

    // A command copied from its rows starts where its own text does.
    if (!command_copy_.empty() && message.pane_id == command_copy_pane_) {
      if (const auto start = text.find(command_copy_.view()); start != std::string_view::npos) {
        text.remove_prefix(start);
      }

      command_copy_.clear();
    }

    clipboard_.assign(text);

    return Change::clipboard;
  }

  Change Session::apply(const PaneProgress& message) {
    auto* pane = findPaneMut(message.pane_id);
    if (pane == nullptr || (pane->progress_state == message.state && pane->progress_percent == message.percent)) {
      return Change::none;
    }

    pane->progress_state = message.state;
    pane->progress_percent = message.percent;
    ++chrome_revision_;

    return Change::model;
  }

  Change Session::apply(const PaneGit& message) {
    auto* pane = findPaneMut(message.pane_id);
    if (pane == nullptr || pane->git == message) {
      return Change::none;
    }

    pane->setGit(message);
    changed_pane_ = pane->id;
    ++chrome_revision_;
    return Change::model;
  }

  Change Session::apply(const PaneShell& message) {
    auto* pane = findPaneMut(message.pane_id);
    if (pane == nullptr || pane->shell == message) {
      return Change::none;
    }

    const auto pane_id = pane->id;
    const bool host_changed = pane->shell_host.view() != message.host;
    const auto previous = pane->setShell(message);

    // The pane's header names the host and the link.
    chrome_changed_ |= previous.remote != message.remote || host_changed || previous.link_ms != message.link_ms;
    if (chrome_changed_) {
      ++chrome_revision_;
    }

    prompt::follow(*this, pane_id, previous, message);

    changed_pane_ = pane_id;
    return Change::terminal;
  }

  Change Session::apply(const PaneDocument& message) {
    auto* pane = findPaneMut(message.pane_id);
    if (pane == nullptr) {
      return Change::none;
    }

    if (message.id != 0) {
      return applyInline(*pane, message);
    }

    if (message.revision != pane->document_revision || message.offset == 0) {
      pane->document_revision = message.revision;
      pane->document_parts.clear();
    }

    if (message.offset != pane->document_parts.size()) {
      return Change::none;
    }

    if (message.size == 0) {
      pane->document_parts.shrinkToFit();
      if (!pane->document_shown) {
        return Change::none;
      }

      pane->document.clear();
      pane->document_shown = false;
    } else {
      pane->document_parts.extend(message.bytes);
      if (pane->document_parts.size() < message.size) {
        return Change::none;
      }

      pane->document_shown = render::decode(pane->document_parts, pane->document) == render::DecodeError::none;
      pane->document_parts.clear();
      pane->document_parts.shrinkToFit();
    }

    ++pane->document_version;
    changed_pane_ = pane->id;
    return Change::document;
  }

  Change Session::applyInline(Pane<Memory>& pane, const PaneDocument& message) {
    using Inline = Pane<Memory>::InlineDocument;
    const auto documents = pane.inline_documents.viewMut();
    const auto found = std::ranges::find(documents, message.id, &Inline::id);

    if (message.size == 0) {
      if (found == documents.end()) {
        return Change::none;
      }

      static_cast<void>(pane.inline_documents.remove(static_cast<std::size_t>(found - documents.begin())));
    } else {
      if (found == documents.end() && message.offset != 0) {
        return Change::none;
      }

      auto& document = found == documents.end() ? pane.inline_documents.emplace(memory, message.id) : *found;
      if (!document.whole) {
        if (message.offset != document.parts.size()) {
          return Change::none;
        }

        document.parts.extend(message.bytes);
        if (document.parts.size() == message.size) {
          document.shown = render::decode(document.parts, document.document) == render::DecodeError::none;
          document.whole = true;
          document.parts.clear();
          document.parts.shrinkToFit();
        }
      }

      if (document.rows != message.rows) {
        document.view_rows = 0;
      }

      document.generation = message.generation;
      document.first_row = message.first_row;
      document.rows = message.rows;
    }

    ++pane.inline_version;
    refreshFolds(pane);
    changed_pane_ = pane.id;
    return Change::document;
  }

  Change Session::apply(const PaneScrollback& message) {
    auto* pane = findPaneMut(message.pane_id);
    if (pane == nullptr) {
      return Change::none;
    }

    const auto selected = selectedBlockKey(*pane);

    if (pane->scrollback_generation == message.generation && message.trimmed > pane->scrollback_trimmed) {
      // The blocks come again with their rows moved up; until then they are moved here, so
      // their folds keep hiding the same rows.
      const auto dropped = message.trimmed - pane->scrollback_trimmed;

      pane->scrollback_dropped += dropped;
      static_cast<void>(pane->blocks.retain([dropped](const CommandBlock& block) {
        return block.row >= dropped;
      }));

      for (auto& block : pane->blocks.viewMut()) {
        block.row -= static_cast<std::uint32_t>(dropped);
      }

      if (pane->live_prompt_row) {
        pane->live_prompt_row = *pane->live_prompt_row >= dropped ? ds::Option{static_cast<std::uint32_t>(*pane->live_prompt_row - dropped)} : ds::none;
      }
    } else if (pane->scrollback_generation != 0 && pane->scrollback_generation != message.generation && !pane->folded.empty()) {
      // Renumbered rows: the blocks come again with their new rows, and their folds follow them
      // by order then.
      pane->refold.clear();
      for (std::size_t index = 0; index < pane->blocks.size(); ++index) {
        if (std::ranges::find(pane->folded, blockKey(*pane, index)) != pane->folded.end()) {
          pane->refold.push(index);
        }
      }

      pane->folded.clear();
    }

    if (pane->scrollback_generation != message.generation) {
      pane->live_prompt_row.reset();
    }

    const bool renumbered = pane->scrollback_generation != message.generation;

    pane->scrollback_generation = message.generation;
    pane->scrollback_trimmed = message.trimmed;
    pane->rows.number(message.generation);
    // Rows dropped from the top keep each block's key; renumbered rows leave nothing to find.
    restoreBlock(*pane, renumbered ? ds::none : selected);
    refreshFolds(*pane);
    changed_pane_ = pane->id;
    return Change::terminal;
  }

  Change Session::apply(const PaneRows& message) {
    auto* pane = findPaneMut(message.pane_id);
    if (pane == nullptr) {
      return Change::none;
    }

    if (!pane->rows.store(message, pane->screen.columns())) {
      return Change::none;
    }

    changed_pane_ = pane->id;
    return Change::terminal;
  }

  Change Session::apply(const PaneText& message) {
    return peek::receive(*this, message);
  }

  Change Session::apply(const PaneMatches& message) {
    return terminal::copy_mode::receive(*this, message);
  }

  bool Session::takeChromeChange() noexcept {
    return std::exchange(chrome_changed_, false);
  }

  void Session::paste(std::uint64_t pane_id, std::string_view bytes) {
    if (features::terminal::copy_mode::view(copy_mode).active()) {
      return;
    }

    if (prompt::edits(*this, pane_id) && !prompt::toProgram(*this, pane_id, bytes)) {
      prompt::text(*this, pane_id, bytes);
      return;
    }

    pasteBytes(pane_id, bytes);
  }

  void Session::pasteBytes(std::uint64_t pane_id, std::string_view bytes) {
    const auto* pane = findPane(pane_id);
    if (pane == nullptr) {
      return;
    }

    BracketedPaste::encode(bytes, pane->screen.modes().bracketed_paste, [&](std::string_view piece) {
      input(pane_id, piece);
    });
  }

}

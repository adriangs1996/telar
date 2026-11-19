module telar.gui.application;

import std;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.gui.features.prompt;
import telar.gui.features.terminal.graphics;
import telar.config.client;
import telar.config.runtime;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.editor;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.shell.syntax;
import telar.base.ds;

namespace telar::gui::application {

  std::uint64_t Session::blockKey(const Pane<Memory>& pane, std::size_t index) noexcept {
    return pane.scrollback_trimmed + pane.blocks[index].row;
  }

  bool Session::folded(std::uint64_t pane_id, std::size_t index) const noexcept {
    const auto* pane = findPane(pane_id);

    return pane != nullptr && index < pane->blocks.size() && std::ranges::find(pane->folded, blockKey(*pane, index)) != pane->folded.end();
  }

  void Session::fold(std::uint64_t pane_id, std::size_t index, bool fold) {
    auto* pane = findPaneMut(pane_id);
    if (pane == nullptr || index >= pane->blocks.size() || (fold && !readsRows())) {
      return;
    }

    const auto key = blockKey(*pane, index);
    const auto found = std::ranges::find(pane->folded, key);
    if (fold == (found != pane->folded.end())) {
      return;
    }

    if (fold) {
      pane->folded.push(key);
    } else {
      static_cast<void>(pane->folded.remove(static_cast<std::size_t>(found - pane->folded.begin())));
    }

    refreshFolds(*pane);
    changed_pane_ = pane_id;
  }

  void Session::foldAll(std::uint64_t pane_id, bool fold) {
    auto* pane = findPaneMut(pane_id);
    if (pane == nullptr || (fold && !readsRows())) {
      return;
    }

    pane->folded.clear();
    for (std::size_t index = 0; fold && index < pane->blocks.size(); ++index) {
      if (pane->blocks[index].state != CommandBlockState::running) {
        pane->folded.push(blockKey(*pane, index));
      }
    }

    refreshFolds(*pane);
    changed_pane_ = pane_id;
  }

  std::pair<std::uint32_t, std::uint32_t> Session::blockRows(const Pane<Memory>& pane, std::size_t index) noexcept {
    const auto& block = pane.blocks[index];
    const auto first = block.row + block.rows;
    std::uint32_t end = pane.screen.scroll().total_rows;

    if (index + 1 < pane.blocks.size()) {
      end = pane.blocks[index + 1].row;
    } else if (block.state != CommandBlockState::running) {
      // The live prompt, read where the view shows it and remembered while it does not.
      const auto live_prompt = livePromptRow(pane);
      if (live_prompt && *live_prompt >= first) {
        end = *live_prompt;
      } else if (pane.live_prompt_row && *pane.live_prompt_row >= first) {
        end = *pane.live_prompt_row;
      }
    }

    return {first, std::max(first, end)};
  }

  ds::Option<std::size_t> Session::selectedBlock(std::uint64_t pane_id) const noexcept {
    const auto block = features::prompt::selectedBlock(prompt_lines, pane_id);
    const auto* pane = findPane(pane_id);
    if (!block || pane == nullptr || *block >= pane->blocks.size()) {
      return ds::none;
    }

    return block;
  }

  void Session::selectBlock(std::uint64_t pane_id, ds::Option<std::size_t> index) {
    const auto* pane = findPane(pane_id);
    if (pane == nullptr) {
      return;
    }

    auto& line = prompt::open(*this, pane_id);

    if (index && *index < pane->blocks.size()) {
      features::prompt::selectBlock(line, index, features::prompt::selectedBlock(line) ? ds::none : livePromptRow(*pane));
      const auto row = pane->blocks[*index].row;

      scrollToRow(pane_id, row == 0 ? 0 : row - 1);
    } else {
      features::prompt::selectBlock(line, ds::none, ds::none);
      scrollToRow(pane_id, std::numeric_limits<std::uint32_t>::max());
    }

    changed_pane_ = pane_id;
    block_changed_ = true;
  }

  bool Session::enterBlocks() {
    auto* pane = focusedPaneMut();
    if (pane == nullptr || configuration.prompt.mode != PromptMode::telar || pane->blocks.empty() || prompt::surface(*this, pane->id) != features::prompt::Surface::editor || selectedBlock(pane->id)) {
      return false;
    }

    selectBlock(pane->id, pane->blocks.size() - 1);
    return true;
  }

  void Session::refreshFolds(Pane<Memory>& pane) {
    if (pane.folded.empty() && pane.inline_documents.empty()) {
      if (!pane.folds.empty()) {
        pane.folds.clear();
        ++pane.fold_revision;
      }

      return;
    }

    ds::Vec<typename FoldMap<>::Span, Memory> spans{memory};

    // Each document drawn in place of its rows, in the rows the view measured it in, while the
    // rows are numbered as the runtime numbered them for it.
    for (const auto& document : pane.inline_documents) {
      if (document.shown && document.view_rows != 0 && document.generation == pane.scrollback_generation && document.first_row >= pane.scrollback_trimmed && document.first_row - pane.scrollback_trimmed <= std::numeric_limits<std::uint32_t>::max()) {
        spans.push({.first = static_cast<std::uint32_t>(document.first_row - pane.scrollback_trimmed), .count = document.rows, .shown = document.view_rows});
      }
    }

    ds::Vec<std::uint64_t, Memory> kept{memory};

    for (std::size_t index = 0; index < pane.blocks.size(); ++index) {
      if (std::ranges::find(pane.folded, blockKey(pane, index)) == pane.folded.end()) {
        continue;
      }

      kept.push(blockKey(pane, index));
      const auto [first, end] = blockRows(pane, index);
      if (end > first) {
        spans.push({.first = first, .count = end - first});
      }
    }

    pane.folded = std::move(kept);
    if (!std::ranges::equal(pane.folds.spans(), spans.view())) {
      pane.folds.assign(spans.view());
      ++pane.fold_revision;
    }
  }

  Change Session::apply(const PaneBlocks& message) {
    auto* pane = findPaneMut(message.pane_id);
    if (pane == nullptr) {
      return Change::none;
    }

    std::size_t bytes = 0;

    for (const auto& block : message.blocks) {
      bytes += block.command.size();
    }

    pane->blocks_text.clear();
    pane->blocks_text.reserve(bytes);
    pane->blocks.clear();
    pane->blocks.extend(message.blocks);
    for (auto& block : pane->blocks.viewMut()) {
      const auto start = pane->blocks_text.size();

      pane->blocks_text.append(block.command);
      block.command = pane->blocks_text.view().substr(start, block.command.size());
    }

    // A command that ran without the shell finding it missing (status 127) exists, though the
    // shell never reported it: a function defined since its last report, say.
    if (!pane->blocks.empty() && !pane->shell.remote) {
      const auto& last = pane->blocks.back();
      if ((last.state == CommandBlockState::succeeded || last.state == CommandBlockState::failed) && last.status != 127) {
        features::prompt::learn(prompt, pane->id, last.command, pane->shell.shell == IntegratedShell::fish ? shell::Dialect::fish : shell::Dialect::posix);
      }
    }

    if (!pane->refold.empty()) {
      for (const auto index : pane->refold) {
        if (index < pane->blocks.size()) {
          pane->folded.push(blockKey(*pane, index));
        }
      }

      pane->refold.clear();
    }

    refreshFolds(*pane);
    changed_pane_ = pane->id;
    return Change::terminal;
  }

  ds::Option<features::prompt::Outcome> Session::blockKey(std::uint64_t pane_id, const features::prompt::KeyPress& key) {
    using features::prompt::Outcome;
    auto* pane = findPaneMut(pane_id);
    auto* found = features::prompt::find(prompt_lines, pane_id);
    if (pane == nullptr || found == nullptr || configuration.prompt.mode != PromptMode::telar) {
      return ds::none;
    }

    auto& line = *found;

    const auto editor = features::prompt::view(prompt, line);
    const bool normal = editor.keymap() == features::prompt::Keymap::vim && editor.mode() == features::prompt::Mode::normal && !editor.commandPending();
    const auto count = pane->blocks.size();
    const auto selection = features::prompt::selectedBlock(line);
    const bool selected = selection && *selection < count;
    if (!selected && !normal) {
      static_cast<void>(features::prompt::takeChord(line));
      return ds::none;
    }

    const bool plain = key.key == features::prompt::Key::character && !key.modifiers.control && !key.modifiers.alt;
    const auto character = plain ? key.character : 0U;
    const auto select = [&](ds::Option<std::size_t> index) {
      recordJump(*pane, line);
      selectBlock(pane_id, index);
    };

    const auto step = [&](int direction) {
      if (count == 0) {
        return;
      }

      if (!selected) {
        if (direction < 0) {
          select(count - 1);
        }

        return;
      }

      if (direction < 0) {
        select(*selection == 0 ? 0 : *selection - 1);
      } else {
        select(*selection + 1 < count ? ds::Option<std::size_t>{*selection + 1} : ds::none);
      }
    };

    // The next failed block above or below the selected one, or from the live end.
    const auto step_failed = [&](int direction) {
      auto index = selected ? static_cast<std::ptrdiff_t>(*selection) : static_cast<std::ptrdiff_t>(count);

      for (index += direction; index >= 0 && std::cmp_less(index, count); index += direction) {
        if (pane->blocks[static_cast<std::size_t>(index)].state == CommandBlockState::failed) {
          select(static_cast<std::size_t>(index));
          return;
        }
      }
    };

    if (key.key == features::prompt::Key::character && key.modifiers.control && !key.modifiers.alt) {
      switch (key.character) {
      case 'u':
      case 'd':
        static_cast<void>(features::prompt::takeChord(line));
        step(key.character == 'u' ? -1 : 1);
        return Outcome::edited;
      case 'o':
      case 'i':
        static_cast<void>(features::prompt::takeChord(line));
        jumpBack(*pane, line, key.character == 'o');
        return Outcome::edited;
      default:
        break;
      }
    }

    const auto pending = features::prompt::takeChord(line);
    if (pending == '[' || pending == ']') {
      const int direction = pending == '[' ? -1 : 1;

      if (character == static_cast<unsigned>(pending)) {
        step(direction);
      } else if (character == 'f') {
        step_failed(direction);
      }

      return Outcome::edited;
    }

    if (character == '[' || character == ']') {
      features::prompt::beginChord(line, static_cast<char>(character));
      return Outcome::edited;
    }

    if (!selected) {
      return ds::none;
    }

    const auto index = *selection;
    const auto& block = pane->blocks[index];
    const auto rows = static_cast<std::uint64_t>(pane->screen.rows());
    const auto top = shownTop(*pane);
    const auto separator = pane->folds.display(static_cast<std::uint64_t>(block.row) + block.rows - 1);

    switch (pending) {
    case 'y':
      if (character == 'c') {
        clipboard_.assign(block.command);
        clipboard_written_ = true;
      }

      return Outcome::edited;
    case 'g':
      if (character == 'g') {
        recordJump(*pane, line);
        scrollToShownRow(*pane, 0);
      }

      return Outcome::edited;
    case 'z':
      switch (character) {
      case 'a':
        fold(pane_id, index, !folded(pane_id, index));
        break;
      case 'c':
        fold(pane_id, index, true);
        break;
      case 'o':
        fold(pane_id, index, false);
        break;
      case 'M':
        foldAll(pane_id, true);
        break;
      case 'R':
        foldAll(pane_id, false);
        break;
      case 't':
        recordJump(*pane, line);
        scrollToShownRow(*pane, separator);
        break;
      case 'z':
        recordJump(*pane, line);
        scrollToShownRow(*pane, separator > rows / 2 ? separator - (rows / 2) : 0);
        break;
      case 'b': {
        recordJump(*pane, line);
        const auto end = pane->folds.display(blockRows(*pane, index).second);

        scrollToShownRow(*pane, end > rows ? end - rows : 0);
        break;
      }
      default:
        break;
      }

      changed_pane_ = pane_id;
      block_changed_ = true;
      return Outcome::edited;
    default:
      break;
    }

    switch (character) {
    case 'j':
    case 'k':
      scrollToShownRow(*pane, character == 'j' ? top + 1 : (top == 0 ? 0 : top - 1));
      return Outcome::edited;
    case 'G':
      select(ds::none);
      return Outcome::edited;
    case 'g':
    case 'z':
    case 'y':
      features::prompt::beginChord(line, static_cast<char>(character));
      return Outcome::edited;
    case '/':
      searchBlockOutput(*pane, index);
      return Outcome::edited;
    case 'v':
    case 'V':
      selectBlockOutput(*pane, index, character == 'V');
      return Outcome::edited;
    case 'Y':
      copyBlockOutput(*pane, index);
      return Outcome::edited;
    case 'q':
      selectBlock(pane_id, ds::none);
      return Outcome::edited;
    default:
      break;
    }

    // Back to the prompt: Esc and q stay in normal mode; i, a, I, A and any other key go on
    // to the editor, which enters insert mode or edits.
    selectBlock(pane_id, ds::none);
    if (key.key == features::prompt::Key::escape) {
      return Outcome::edited;
    }

    return ds::none;
  }

  std::uint64_t Session::shownTop(const Pane<Memory>& pane) noexcept {
    return pane.shown_top.valueOr(pane.folds.display(pane.screen.scroll().offset));
  }

  void Session::scrollToShownRow(const Pane<Memory>& pane, std::uint64_t display) {
    const auto row = pane.folds.row(display);

    scrollToRow(pane.id, static_cast<std::uint32_t>(std::min<std::uint64_t>(row, std::numeric_limits<std::uint32_t>::max())));
    changed_pane_ = pane.id;
    block_changed_ = true;
  }

  std::uint64_t Session::jumpRow(const Pane<Memory>& pane) noexcept {
    return pane.scrollback_trimmed + pane.folds.row(shownTop(pane));
  }

  void Session::recordJump(const Pane<Memory>& pane, features::prompt::PaneLine& line) {
    features::prompt::recordJump(line, jumpRow(pane));
  }

  void Session::jumpBack(const Pane<Memory>& pane, features::prompt::PaneLine& line, bool back) {
    const auto target = features::prompt::jump(line, jumpRow(pane), back);
    if (!target) {
      return;
    }

    const auto stable = *target;
    const auto row = stable > pane.scrollback_trimmed ? stable - pane.scrollback_trimmed : 0;

    scrollToRow(pane.id, static_cast<std::uint32_t>(std::min<std::uint64_t>(row, std::numeric_limits<std::uint32_t>::max())));
    changed_pane_ = pane.id;
    block_changed_ = true;
  }

  void Session::searchBlockOutput(Pane<Memory>& pane, std::size_t index) {
    const auto [first, last] = blockOutput(pane, index);
    const auto grid = copyGrid(pane.screen);

    if (folded(pane.id, index)) {
      fold(pane.id, index, false);
    }

    if (features::terminal::copy_mode::searchOutput(copy_mode, pane.id, grid, {.block = index, .first = first, .last = last}, readsRows())) {
      changed_pane_ = pane.id;
      block_changed_ = true;
    }
  }

  std::pair<std::uint32_t, std::uint32_t> Session::blockOutput(const Pane<Memory>& pane, std::size_t index) const {
    const auto& block = pane.blocks[index];
    const auto first = block.row + block.rows;
    std::uint32_t end = pane.screen.scroll().total_rows;

    if (index + 1 < pane.blocks.size()) {
      end = pane.blocks[index + 1].row;
    } else if (const auto live = features::prompt::livePrompt(prompt_lines, pane.id)) {
      end = *live;
    }

    return {first, std::max(first, end == 0 ? 0 : end - 1)};
  }

  void Session::selectBlockOutput(const Pane<Memory>& pane, std::size_t index, bool lines) {
    const auto [first, last] = blockOutput(pane, index);
    const auto grid = copyGrid(pane.screen);
    const auto columns = static_cast<std::uint16_t>(grid.columns == 0 ? 0 : grid.columns - 1);
    const CopyPoint start{.x = 0, .y = first};
    if (features::terminal::copy_mode::select(copy_mode, pane.id, grid, lines ? CopyPoint{.x = columns, .y = last} : start, start, lines)) {
      changed_pane_ = pane.id;
      block_changed_ = true;
    }
  }

  void Session::copyBlockOutput(const Pane<Memory>& pane, std::size_t index) {
    const auto [first, last] = blockOutput(pane, index);
    const auto columns = pane.screen.columns();

    link.send(CopySelection{.pane_id = pane.id, .start_x = 0, .start_y = first, .end_x = static_cast<std::uint16_t>(columns == 0 ? 0 : columns - 1), .end_y = last, .linewise = true});
  }

  bool Session::takeBlockChange() noexcept {
    return std::exchange(block_changed_, false);
  }

  bool Session::takeClipboardWrite() noexcept {
    return std::exchange(clipboard_written_, false);
  }

  void Session::scrollToRow(std::uint64_t pane_id, std::uint32_t row) {
    const auto* pane = findPane(pane_id);
    if (pane != nullptr) {
      scroll(PaneScrollDelta{.pane_id = pane_id, .rows = static_cast<std::int64_t>(pane->screen.scroll().offset) - static_cast<std::int64_t>(row)});
    }
  }

  ds::Option<std::uint32_t> Session::livePromptRow(const Pane<Memory>& pane) {
    const auto& screen = pane.screen;
    const auto& scroll = screen.scroll();
    if (static_cast<std::uint64_t>(scroll.offset) + screen.rows() < scroll.total_rows) {
      return ds::none;
    }

    const auto cursor = static_cast<std::size_t>(screen.cursor().y);

    for (auto row = cursor + 1; row-- > 0 && cursor - row < 8;) {
      if ((screen.rowFlags(row) & static_cast<Byte>(RowFlag::prompt)) != 0) {
        return scroll.offset + static_cast<std::uint32_t>(row);
      }
    }

    return ds::none;
  }

}

module telar.gui.application.session;

import std;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;

namespace telar::gui {

  std::uint64_t Session::blockKey(const Pane<Memory>& pane, std::size_t index) noexcept {
    return pane.scrollback_trimmed + pane.blocks[index].row;
  }

  bool Session::folded(std::uint64_t pane_id, std::size_t index) const noexcept {
    const auto* pane = findPane(pane_id);

    return pane != nullptr && index < pane->blocks.size() && std::ranges::find(pane->folded, blockKey(*pane, index)) != pane->folded.end();
  }

  void Session::fold(std::uint64_t pane_id, std::size_t index, bool fold) {
    auto* pane = findPane(pane_id);
    if (pane == nullptr || index >= pane->blocks.size() || (fold && !readsRows())) {
      return;
    }

    const auto key = blockKey(*pane, index);
    const auto found = std::ranges::find(pane->folded, key);
    if (fold == (found != pane->folded.end())) {
      return;
    }

    if (fold) {
      pane->folded.push_back(key);
    } else {
      pane->folded.erase(found);
    }

    refreshFolds(*pane);
    changed_pane_ = pane_id;
  }

  void Session::foldAll(std::uint64_t pane_id, bool fold) {
    auto* pane = findPane(pane_id);
    if (pane == nullptr || (fold && !readsRows())) {
      return;
    }

    pane->folded.clear();
    for (std::size_t index = 0; fold && index < pane->blocks.size(); ++index) {
      if (pane->blocks[index].state != CommandBlockState::running) {
        pane->folded.push_back(blockKey(*pane, index));
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
      const auto prompt = livePromptRow(pane);
      if (prompt && *prompt >= first) {
        end = *prompt;
      } else if (pane.live_prompt_row && *pane.live_prompt_row >= first) {
        end = *pane.live_prompt_row;
      }
    }

    return {first, std::max(first, end)};
  }

  std::optional<std::size_t> Session::selectedBlock(std::uint64_t pane_id) const noexcept {
    const auto found = lines_.find(pane_id);
    const auto* pane = findPane(pane_id);
    if (found == lines_.end() || pane == nullptr || !found->second.block || *found->second.block >= pane->blocks.size()) {
      return std::nullopt;
    }

    return found->second.block;
  }

  void Session::selectBlock(std::uint64_t pane_id, std::optional<std::size_t> index) {
    const auto* pane = findPane(pane_id);
    if (pane == nullptr) {
      return;
    }

    auto& entry = lineEntry(pane_id);

    entry.pending = 0;
    if (index && *index < pane->blocks.size()) {
      if (!entry.block) {
        entry.live_prompt = livePromptRow(*pane);
      }

      entry.block = index;
      const auto row = pane->blocks[*index].row;

      scrollToRow(pane_id, row == 0 ? 0 : row - 1);
    } else {
      entry.block.reset();
      scrollToRow(pane_id, std::numeric_limits<std::uint32_t>::max());
    }

    changed_pane_ = pane_id;
    block_changed_ = true;
  }

  bool Session::enterBlocks() {
    const auto* pane = focusedPane();
    if (pane == nullptr || configuration_.prompt.mode != PromptMode::telar || pane->blocks.empty() || promptSurface(pane->id) != prompt::Surface::editor || selectedBlock(pane->id)) {
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

    std::vector<typename FoldMap<>::Span> spans;

    // Each document drawn in place of its rows, in the rows the view measured it in, while the
    // rows are numbered as the runtime numbered them for it.
    for (const auto& document : pane.inline_documents) {
      if (document.shown && document.view_rows != 0 && document.generation == pane.scrollback_generation && document.first_row >= pane.scrollback_trimmed && document.first_row - pane.scrollback_trimmed <= std::numeric_limits<std::uint32_t>::max()) {
        spans.push_back({.first = static_cast<std::uint32_t>(document.first_row - pane.scrollback_trimmed), .count = document.rows, .shown = document.view_rows});
      }
    }

    std::vector<std::uint64_t> kept;

    for (std::size_t index = 0; index < pane.blocks.size(); ++index) {
      if (std::ranges::find(pane.folded, blockKey(pane, index)) == pane.folded.end()) {
        continue;
      }

      kept.push_back(blockKey(pane, index));
      const auto [first, end] = blockRows(pane, index);
      if (end > first) {
        spans.push_back({.first = first, .count = end - first});
      }
    }

    pane.folded = std::move(kept);
    if (!std::ranges::equal(pane.folds.spans(), spans)) {
      pane.folds.assign(spans);
      ++pane.fold_revision;
    }
  }

  Change Session::apply(const PaneBlocks& message) {
    auto* pane = findPane(message.pane_id);
    if (pane == nullptr) {
      return Change::none;
    }

    std::size_t bytes = 0;

    for (const auto& block : message.blocks) {
      bytes += block.command.size();
    }

    pane->blocks_text.clear();
    pane->blocks_text.reserve(bytes);
    pane->blocks.assign(message.blocks.begin(), message.blocks.end());
    for (auto& block : pane->blocks) {
      const auto start = pane->blocks_text.size();

      pane->blocks_text.append(block.command);
      block.command = std::string_view{pane->blocks_text}.substr(start, block.command.size());
    }

    // A command that ran without the shell finding it missing (status 127) exists, though the
    // shell never reported it: a function defined since its last report, say.
    if (!pane->blocks.empty() && !pane->shell.remote) {
      const auto& last = pane->blocks.back();
      if ((last.state == CommandBlockState::succeeded || last.state == CommandBlockState::failed) && last.status != 127) {
        learnCommand(pane->id, last.command, pane->shell.shell == IntegratedShell::fish ? shell::Dialect::fish : shell::Dialect::posix);
      }
    }

    if (!pane->refold.empty()) {
      for (const auto index : pane->refold) {
        if (index < pane->blocks.size()) {
          pane->folded.push_back(blockKey(*pane, index));
        }
      }

      pane->refold.clear();
    }

    refreshFolds(*pane);
    changed_pane_ = pane->id;
    return Change::terminal;
  }

  std::optional<prompt::Outcome> Session::blockKey(std::uint64_t pane_id, LineEntry& entry, const prompt::KeyPress& key) {
    auto* pane = findPane(pane_id);
    if (pane == nullptr || configuration_.prompt.mode != PromptMode::telar) {
      return std::nullopt;
    }

    const auto& editor = entry.line.editor();
    const bool normal = editor.keymap() == prompt::Keymap::vim && editor.mode() == prompt::Mode::normal && !editor.pending();
    const auto count = pane->blocks.size();
    const bool selected = entry.block && *entry.block < count;
    if (!selected && !normal) {
      entry.pending = 0;
      return std::nullopt;
    }

    const bool plain = key.key == prompt::Key::character && !key.modifiers.control && !key.modifiers.alt;
    const auto character = plain ? key.character : 0U;
    const auto select = [&](std::optional<std::size_t> index) {
      recordJump(*pane, entry);
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
        select(*entry.block == 0 ? 0 : *entry.block - 1);
      } else {
        select(*entry.block + 1 < count ? std::optional<std::size_t>{*entry.block + 1} : std::nullopt);
      }
    };

    // The next failed block above or below the selected one, or from the live end.
    const auto step_failed = [&](int direction) {
      auto index = selected ? static_cast<std::ptrdiff_t>(*entry.block) : static_cast<std::ptrdiff_t>(count);

      for (index += direction; index >= 0 && std::cmp_less(index, count); index += direction) {
        if (pane->blocks[static_cast<std::size_t>(index)].state == CommandBlockState::failed) {
          select(static_cast<std::size_t>(index));
          return;
        }
      }
    };

    if (key.key == prompt::Key::character && key.modifiers.control && !key.modifiers.alt) {
      switch (key.character) {
      case 'u':
      case 'd':
        entry.pending = 0;
        step(key.character == 'u' ? -1 : 1);
        return prompt::Outcome::edited;
      case 'o':
      case 'i':
        entry.pending = 0;
        jumpBack(*pane, entry, key.character == 'o');
        return prompt::Outcome::edited;
      default:
        break;
      }
    }

    const auto pending = std::exchange(entry.pending, 0);
    if (pending == '[' || pending == ']') {
      const int direction = pending == '[' ? -1 : 1;

      if (character == static_cast<unsigned>(pending)) {
        step(direction);
      } else if (character == 'f') {
        step_failed(direction);
      }

      return prompt::Outcome::edited;
    }

    if (character == '[' || character == ']') {
      entry.pending = static_cast<char>(character);
      return prompt::Outcome::edited;
    }

    if (!selected) {
      return std::nullopt;
    }

    const auto index = *entry.block;
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

      return prompt::Outcome::edited;
    case 'g':
      if (character == 'g') {
        recordJump(*pane, entry);
        scrollToShownRow(*pane, 0);
      }

      return prompt::Outcome::edited;
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
        recordJump(*pane, entry);
        scrollToShownRow(*pane, separator);
        break;
      case 'z':
        recordJump(*pane, entry);
        scrollToShownRow(*pane, separator > rows / 2 ? separator - (rows / 2) : 0);
        break;
      case 'b': {
        recordJump(*pane, entry);
        const auto end = pane->folds.display(blockRows(*pane, index).second);

        scrollToShownRow(*pane, end > rows ? end - rows : 0);
        break;
      }
      default:
        break;
      }

      changed_pane_ = pane_id;
      block_changed_ = true;
      return prompt::Outcome::edited;
    default:
      break;
    }

    switch (character) {
    case 'j':
    case 'k':
      scrollToShownRow(*pane, character == 'j' ? top + 1 : (top == 0 ? 0 : top - 1));
      return prompt::Outcome::edited;
    case 'G':
      select(std::nullopt);
      return prompt::Outcome::edited;
    case 'g':
    case 'z':
    case 'y':
      entry.pending = static_cast<char>(character);
      return prompt::Outcome::edited;
    case '/':
      searchBlockOutput(*pane, index);
      return prompt::Outcome::edited;
    case 'v':
    case 'V':
      selectBlockOutput(*pane, index, character == 'V');
      return prompt::Outcome::edited;
    case 'Y':
      copyBlockOutput(*pane, index);
      return prompt::Outcome::edited;
    case 'q':
      selectBlock(pane_id, std::nullopt);
      return prompt::Outcome::edited;
    default:
      break;
    }

    // Back to the prompt: Esc and q stay in normal mode; i, a, I, A and any other key go on
    // to the editor, which enters insert mode or edits.
    selectBlock(pane_id, std::nullopt);
    if (key.key == prompt::Key::escape) {
      return prompt::Outcome::edited;
    }

    return std::nullopt;
  }

  std::uint64_t Session::shownTop(const Pane<Memory>& pane) noexcept {
    return pane.shown_top.value_or(pane.folds.display(pane.screen.scroll().offset));
  }

  void Session::scrollToShownRow(const Pane<Memory>& pane, std::uint64_t display) {
    const auto row = pane.folds.row(display);

    scrollToRow(pane.id, static_cast<std::uint32_t>(std::min<std::uint64_t>(row, std::numeric_limits<std::uint32_t>::max())));
    changed_pane_ = pane.id;
    block_changed_ = true;
  }

  void Session::recordJump(const Pane<Memory>& pane, LineEntry& entry) {
    constexpr std::size_t maximum_jumps = 64;
    const auto here = pane.scrollback_trimmed + pane.folds.row(shownTop(pane));

    entry.jumps.resize(std::min(entry.jump, entry.jumps.size()));
    if (entry.jumps.empty() || entry.jumps.back() != here) {
      entry.jumps.push_back(here);
    }

    if (entry.jumps.size() > maximum_jumps) {
      entry.jumps.erase(entry.jumps.begin());
    }

    entry.jump = entry.jumps.size();
  }

  void Session::jumpBack(const Pane<Memory>& pane, LineEntry& entry, bool back) {
    if (back) {
      if (entry.jump == 0 || entry.jumps.empty()) {
        return;
      }

      if (entry.jump == entry.jumps.size()) {
        // The first step back remembers where it left, for Ctrl-I to return to.
        const auto here = pane.scrollback_trimmed + pane.folds.row(shownTop(pane));
        if (entry.jumps.back() != here) {
          entry.jumps.push_back(here);
        }

        entry.jump = entry.jumps.size() - 1;
      }

      --entry.jump;
    } else {
      if (entry.jump + 1 >= entry.jumps.size()) {
        return;
      }

      ++entry.jump;
    }

    const auto stable = entry.jumps[entry.jump];
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

    if (copy_mode_.enterAt(pane.id, grid, CopyPoint{.x = 0, .y = first}, std::nullopt, false)) {
      copy_search_request_ = 0;
      copy_search_rows_ = CopySearchRows{.block = index, .first = first, .last = last};
      copy_search_origin_ = CopyPoint{.x = 0, .y = first};
      copy_search_scoped_ = readsRows();
      search_requested_ = true;
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
    } else if (const auto found = lines_.find(pane.id); found != lines_.end() && found->second.live_prompt) {
      end = *found->second.live_prompt;
    }

    return {first, std::max(first, end == 0 ? 0 : end - 1)};
  }

  void Session::selectBlockOutput(const Pane<Memory>& pane, std::size_t index, bool lines) {
    const auto [first, last] = blockOutput(pane, index);
    const auto grid = copyGrid(pane.screen);
    const auto columns = static_cast<std::uint16_t>(grid.columns == 0 ? 0 : grid.columns - 1);
    const CopyPoint start{.x = 0, .y = first};
    if (copy_mode_.enterAt(pane.id, grid, lines ? CopyPoint{.x = columns, .y = last} : start, start, lines)) {
      copy_search_request_ = 0;
      changed_pane_ = pane.id;
      block_changed_ = true;
    }
  }

  void Session::copyBlockOutput(const Pane<Memory>& pane, std::size_t index) {
    const auto [first, last] = blockOutput(pane, index);
    const auto columns = pane.screen.columns();

    send(CopySelection{.pane_id = pane.id, .start_x = 0, .start_y = first, .end_x = static_cast<std::uint16_t>(columns == 0 ? 0 : columns - 1), .end_y = last, .linewise = true});
  }

}

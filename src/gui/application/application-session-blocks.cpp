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

  bool Session::folded(BlockAt block) const noexcept {
    const auto [pane_id, index] = block;
    const auto* pane = findPane(pane_id);

    return pane != nullptr && index < pane->blocks.size() && std::ranges::find(pane->folded, blockKey(*pane, index)) != pane->folded.end();
  }

  void Session::fold(BlockAt block, bool fold) {
    const auto [pane_id, index] = block;
    auto* pane = findPaneMut(pane_id);
    if (pane == nullptr || index >= pane->blocks.size() || (fold && !readsRows())) {
      return;
    }

    const auto key = blockKey(*pane, index);
    const auto* const found = std::ranges::find(pane->folded, key);
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

  std::uint64_t Session::separatorRow(const Pane<Memory>& pane, std::size_t index) noexcept {
    return pane.blocks[index].row;
  }

  ds::Option<std::size_t> Session::selectedBlock(std::uint64_t pane_id) const noexcept {
    const auto block = features::prompt::selectedBlock(prompt_lines, pane_id);
    const auto* pane = findPane(pane_id);
    if (!block || pane == nullptr || *block >= pane->blocks.size()) {
      return ds::none;
    }

    return *block;
  }

  bool Session::typingLeavesBlock(std::uint64_t pane_id) const noexcept {
    return selectedBlock(pane_id) && features::prompt::typingLeavesBlock(prompt_lines, pane_id);
  }

  void Session::selectBlock(std::uint64_t pane_id, ds::Option<std::size_t> index, bool typing_leaves) {
    const auto* pane = findPane(pane_id);
    if (pane == nullptr) {
      return;
    }

    auto& line = prompt::open(*this, pane_id);

    if (index && *index < pane->blocks.size()) {
      // Stepping from a block the pointer selected keeps the keys for the editor.
      const auto selected = features::prompt::selectedBlock(line);

      features::prompt::selectBlock(line, index, typing_leaves || (selected && features::prompt::typingLeavesBlock(line)));
      const auto separator = pane->folds.display(separatorRow(*pane, *index));
      const auto top = shownTop(*pane);
      // The separator and a row of its output in view, clear of the line docked at the bottom:
      // the view stays. Otherwise the separator comes to the top, where no pinned one covers it.
      constexpr std::uint64_t docked_rows = 2;
      const auto rows = static_cast<std::uint64_t>(pane->screen.rows());

      if (separator < top || separator + docked_rows >= top + rows) {
        scrollToShownRow(*pane, separator);
      }
    } else {
      features::prompt::selectBlock(line, ds::none);
      scrollToRow(pane_id, std::numeric_limits<std::uint32_t>::max());
    }

    changed_pane_ = pane_id;
    block_changed_ = true;
  }

  bool Session::enterBlocks() {
    const auto* pane = focusedPaneMut();
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

    ds::Vec<FoldMap<>::Span, Memory> spans{memory};

    // Each document drawn in place of its rows, in the rows the view measured it in, while the
    // rows are numbered as the runtime numbered them for it.
    for (const auto& document : pane.inline_documents) {
      if (document.shown && document.view_rows != 0 && document.generation == pane.scrollback_generation && document.first_row >= pane.scrollback_trimmed && document.first_row - pane.scrollback_trimmed <= std::numeric_limits<std::uint32_t>::max()) {
        spans.push({.first = static_cast<std::uint32_t>(document.first_row - pane.scrollback_trimmed), .count = document.rows, .shown = document.view_rows});
      }
    }

    for (std::size_t index = 0; index < pane.blocks.size(); ++index) {
      if (std::ranges::find(pane.folded, blockKey(pane, index)) == pane.folded.end()) {
        continue;
      }

      const auto [first, end] = blockRows(pane, index);
      if (end > first) {
        spans.push({.first = first, .count = end - first});
      }
    }

    // A fold stays while a command still starts at its row.
    pane.folded.retain([&blocks = pane.blocks, trimmed = pane.scrollback_trimmed](std::uint64_t key) {
      return std::ranges::any_of(blocks, [&](const CommandBlock& block) {
        return trimmed + block.row == key;
      });
    });

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

    // The selected block stays selected wherever it now is among the blocks.
    const auto selected = selectedBlockKey(*pane);

    pane->setBlocks(message.blocks);
    restoreBlock(*pane, selected);

    // A command that ran without the shell finding it missing exists, though the shell never
    // reported it: a function defined since its last report, say.
    constexpr std::int32_t command_not_found = 127;

    if (!pane->blocks.empty() && !pane->shell.remote) {
      const auto& last = pane->blocks.back();
      if ((last.state == CommandBlockState::succeeded || last.state == CommandBlockState::failed) && last.status != command_not_found) {
        features::prompt::learn(prompt, pane->id, last.command, pane->shell.shell == IntegratedShell::fish ? shell::Dialect::fish : shell::Dialect::posix);
      }
    }

    if (!pane->refold.empty()) {
      for (std::size_t at = 0; at < pane->refold.size(); ++at) {
        if (const auto index = pane->refold[at]; index < pane->blocks.size()) {
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
    const auto* pane = findPaneMut(pane_id);
    auto* found = features::prompt::find(prompt_lines, pane_id);
    if (pane == nullptr || found == nullptr || configuration.prompt.mode != PromptMode::telar) {
      return ds::none;
    }

    const auto editor = features::prompt::view(prompt, *found);
    const bool normal = editor.keymap() == features::prompt::Keymap::vim && editor.mode() == features::prompt::Mode::normal && !editor.commandPending();
    const auto selection = blockSelection(*pane, *found);
    if (!selection && !normal) {
      static_cast<void>(features::prompt::takeChord(*found));
      return ds::none;
    }

    if (selection && !normal && features::prompt::typingLeavesBlock(*found)) {
      return typingBlockKey(pane_id, key);
    }

    const bool plain = key.key == features::prompt::Key::character && !key.modifiers.control && !key.modifiers.alt;
    const auto character = plain ? key.character : 0U;
    const bool control = key.key == features::prompt::Key::character && key.modifiers.control && !key.modifiers.alt;
    if (control && controlBlockKey(pane_id, key.character)) {
      return Outcome::edited;
    }

    if (chordKey(pane_id, selection, character)) {
      return Outcome::edited;
    }

    if (!selection) {
      return ds::none;
    }

    // The arrows step through the blocks while one is selected.
    const bool bare = !key.modifiers.control && !key.modifiers.alt && !key.modifiers.shift;
    if (bare && (key.key == features::prompt::Key::up || key.key == features::prompt::Key::down)) {
      stepBlock(pane_id, key.key == features::prompt::Key::up ? BlockStep::up : BlockStep::down);
      return Outcome::edited;
    }

    if (blockCommand({.pane_id = pane_id, .index = *selection}, character)) {
      return Outcome::edited;
    }

    // Back to the prompt: Esc and q stay in normal mode; i, a, I, A and any other key go on
    // to the editor, which enters insert mode or edits.
    selectBlock(pane_id, ds::none);
    if (key.key == features::prompt::Key::escape) {
      return Outcome::edited;
    }

    return ds::none;
  }

  bool Session::chordKey(std::uint64_t pane_id, ds::Option<std::size_t> selection, char32_t character) {
    auto* line = features::prompt::find(prompt_lines, pane_id);
    if (line == nullptr) {
      return false;
    }

    const auto pending = features::prompt::takeChord(*line);
    if (pending == '[' || pending == ']') {
      const auto direction = pending == '[' ? BlockStep::up : BlockStep::down;

      if (character == static_cast<unsigned char>(pending)) {
        stepBlock(pane_id, direction);
        return true;
      }

      if (character == 'f') {
        stepFailedBlock(pane_id, direction);
        return true;
      }
    } else if (pending != 0 && selection && blockChord(pending, {.pane_id = pane_id, .index = *selection}, character)) {
      return true;
    }

    if (character != '[' && character != ']') {
      return false;
    }

    // blockChord reaches the lines through the session, so the line is looked up again.
    if (auto* chord_line = features::prompt::find(prompt_lines, pane_id); chord_line != nullptr) {
      features::prompt::beginChord(*chord_line, static_cast<char>(character));
    }

    return true;
  }

  ds::Option<features::prompt::Outcome> Session::typingBlockKey(std::uint64_t pane_id, const features::prompt::KeyPress& key) {
    using features::prompt::Outcome;
    const bool bare = !key.modifiers.control && !key.modifiers.alt && !key.modifiers.shift;

    if (bare && (key.key == features::prompt::Key::up || key.key == features::prompt::Key::down)) {
      stepBlock(pane_id, key.key == features::prompt::Key::up ? BlockStep::up : BlockStep::down);
      return Outcome::edited;
    }

    selectBlock(pane_id, ds::none);

    return key.key == features::prompt::Key::escape ? ds::Option<Outcome>{Outcome::edited} : ds::none;
  }

  ds::Option<std::uint64_t> Session::selectedBlockKey(const Pane<Memory>& pane) const noexcept {
    const auto selected = selectedBlock(pane.id);

    return selected ? ds::Option<std::uint64_t>{blockKey(pane, *selected)} : ds::none;
  }

  void Session::restoreBlock(const Pane<Memory>& pane, ds::Option<std::uint64_t> key) {
    auto* line = features::prompt::find(prompt_lines, pane.id);
    if (!key || line == nullptr) {
      return;
    }

    ds::Option<std::size_t> index;

    for (std::size_t at = 0; at < pane.blocks.size(); ++at) {
      if (blockKey(pane, at) == *key) {
        index = at;
        break;
      }
    }

    if (index != features::prompt::selectedBlock(*line)) {
      features::prompt::moveBlock(*line, index);
      block_changed_ = true;
      changed_pane_ = pane.id;
    }
  }

  ds::Option<std::size_t> Session::blockSelection(const Pane<Memory>& pane, const features::prompt::PaneLine& line) noexcept {
    const auto selection = features::prompt::selectedBlock(line);

    return selection && *selection < pane.blocks.size() ? selection : ds::none;
  }

  void Session::jumpToBlock(std::uint64_t pane_id, ds::Option<std::size_t> index) {
    const auto* pane = findPaneMut(pane_id);
    auto* line = features::prompt::find(prompt_lines, pane_id);
    if (pane != nullptr && line != nullptr) {
      recordJump(*pane, *line);
    }

    selectBlock(pane_id, index);
  }

  void Session::stepBlock(std::uint64_t pane_id, BlockStep direction) {
    const auto* pane = findPaneMut(pane_id);
    const auto* line = features::prompt::find(prompt_lines, pane_id);
    if (pane == nullptr || line == nullptr || pane->blocks.empty()) {
      return;
    }

    const auto count = pane->blocks.size();
    const auto selection = blockSelection(*pane, *line);
    if (!selection) {
      if (direction == BlockStep::up) {
        jumpToBlock(pane_id, count - 1);
      }

      return;
    }

    if (direction == BlockStep::up) {
      jumpToBlock(pane_id, *selection == 0 ? 0 : *selection - 1);
    } else {
      jumpToBlock(pane_id, *selection + 1 < count ? ds::Option<std::size_t>{*selection + 1} : ds::none);
    }
  }

  void Session::stepFailedBlock(std::uint64_t pane_id, BlockStep direction) {
    const auto* pane = findPaneMut(pane_id);
    const auto* line = features::prompt::find(prompt_lines, pane_id);
    if (pane == nullptr || line == nullptr) {
      return;
    }

    const auto count = pane->blocks.size();
    auto index = static_cast<std::ptrdiff_t>(blockSelection(*pane, *line).valueOr(count));

    const auto step = std::to_underlying(direction);

    for (index += step; index >= 0 && std::cmp_less(index, count); index += step) {
      if (pane->blocks[static_cast<std::size_t>(index)].state == CommandBlockState::failed) {
        jumpToBlock(pane_id, static_cast<std::size_t>(index));
        return;
      }
    }
  }

  bool Session::controlBlockKey(std::uint64_t pane_id, char32_t character) {
    const auto* pane = findPaneMut(pane_id);
    auto* line = features::prompt::find(prompt_lines, pane_id);
    if (pane == nullptr || line == nullptr) {
      return false;
    }

    switch (character) {
    case 'u':
    case 'd':
      static_cast<void>(features::prompt::takeChord(*line));
      stepBlock(pane_id, character == 'u' ? BlockStep::up : BlockStep::down);
      return true;
    case 'o':
    case 'i':
      static_cast<void>(features::prompt::takeChord(*line));
      if (const auto row = jumpTarget(*pane, *line, character == 'o')) {
        // The block the jump lands in is the one selected, so the keys after it act there.
        const auto blocks = pane->blocks.view();
        const auto landed = std::ranges::find_if(blocks.rbegin(), blocks.rend(), [target = *row](const CommandBlock& block) {
          return block.row <= target;
        });
        if (landed != blocks.rend() && blockSelection(*pane, *line)) {
          features::prompt::moveBlock(*line, static_cast<std::size_t>(blocks.rend() - landed - 1));
        }

        scrollToRow(pane_id, *row);
        changed_pane_ = pane_id;
        block_changed_ = true;
      }

      return true;
    default:
      return false;
    }
  }

  bool Session::blockChord(char pending, BlockAt block, char32_t character) {
    const auto [pane_id, index] = block;
    const auto* pane = findPaneMut(pane_id);
    auto* line = features::prompt::find(prompt_lines, pane_id);
    if (pane == nullptr || line == nullptr) {
      return false;
    }

    switch (pending) {
    case 'y':
      // yc, and yy as vim's reflex, copy the command.
      if (character != 'c' && character != 'y') {
        return false;
      }

      static_cast<void>(copyBlock(block, BlockCopy::command));
      return true;
    case 'g':
      if (character != 'g') {
        return false;
      }

      // The first command, from the top of the scrollback.
      recordJump(*pane, *line);
      selectBlock(pane_id, std::size_t{0});
      scrollToShownRow(*pane, 0);
      return true;
    case 'z':
      if (!foldChord(block, character)) {
        return false;
      }

      changed_pane_ = pane_id;
      block_changed_ = true;
      return true;
    default:
      return false;
    }
  }

  bool Session::foldChord(BlockAt block, char32_t character) {
    const auto [pane_id, index] = block;
    const auto* pane = findPaneMut(pane_id);
    auto* line = features::prompt::find(prompt_lines, pane_id);
    if (pane == nullptr || line == nullptr) {
      return false;
    }

    const auto rows = static_cast<std::uint64_t>(pane->screen.rows());
    const auto separator = pane->folds.display(separatorRow(*pane, index));

    switch (character) {
    case 'a':
      fold(block, !folded(block));
      break;
    case 'c':
      fold(block, true);
      break;
    case 'o':
      fold(block, false);
      break;
    case 'M':
      foldAll(pane_id, true);
      break;
    case 'R':
      foldAll(pane_id, false);
      break;
    case 't':
      recordJump(*pane, *line);
      scrollToShownRow(*pane, separator);
      break;
    case 'z':
      recordJump(*pane, *line);
      scrollToShownRow(*pane, separator > rows / 2 ? separator - (rows / 2) : 0);
      break;
    case 'b': {
      recordJump(*pane, *line);
      const auto end = pane->folds.display(blockRows(*pane, index).second);

      scrollToShownRow(*pane, end > rows ? end - rows : 0);
      break;
    }
    default:
      return false;
    }

    return true;
  }

  bool Session::blockCommand(BlockAt block, char32_t character) {
    const auto [pane_id, index] = block;
    auto* pane = findPaneMut(pane_id);
    auto* line = features::prompt::find(prompt_lines, pane_id);
    if (pane == nullptr || line == nullptr) {
      return false;
    }

    switch (character) {
    case 'j':
      scrollToShownRow(*pane, shownTop(*pane) + 1);
      return true;
    case 'k': {
      const auto top = shownTop(*pane);

      scrollToShownRow(*pane, top == 0 ? 0 : top - 1);
      return true;
    }
    case 'G':
      jumpToBlock(pane_id, ds::none);
      return true;
    case 'g':
    case 'z':
    case 'y':
      features::prompt::beginChord(*line, static_cast<char>(character));
      return true;
    case '/':
      searchBlockOutput(*pane, index);
      return true;
    case 'v':
    case 'V':
      selectBlockOutput(*pane, index, character == 'V');
      return true;
    case 'Y':
      static_cast<void>(copyBlock(block, BlockCopy::output));
      return true;
    case 'q':
      selectBlock(pane_id, ds::none);
      return true;
    default:
      return false;
    }
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

  ds::Option<std::uint32_t> Session::jumpTarget(const Pane<Memory>& pane, features::prompt::PaneLine& line, bool back) {
    const auto target = features::prompt::jump(line, jumpRow(pane), back);
    if (!target) {
      return ds::none;
    }

    const auto stable = *target;
    const auto row = stable > pane.scrollback_trimmed ? stable - pane.scrollback_trimmed : 0;

    return static_cast<std::uint32_t>(std::min<std::uint64_t>(row, std::numeric_limits<std::uint32_t>::max()));
  }

  void Session::searchBlockOutput(Pane<Memory>& pane, std::size_t index) {
    const auto output = blockOutput(pane, index);
    if (!output) {
      return;
    }

    const auto [first, last] = *output;
    const auto grid = copyGrid(pane.screen);

    if (folded({.pane_id = pane.id, .index = index})) {
      fold({.pane_id = pane.id, .index = index}, false);
    }

    if (features::terminal::copy_mode::searchOutput(copy_mode, pane.id, grid, {.block = index, .first = first, .last = last}, readsRows())) {
      changed_pane_ = pane.id;
      block_changed_ = true;
    }
  }

  ds::Option<std::pair<std::uint32_t, std::uint32_t>> Session::blockOutput(const Pane<Memory>& pane, std::size_t index) noexcept {
    const auto [first, end] = blockRows(pane, index);
    if (end <= first) {
      return ds::none;
    }

    return std::pair{first, end - 1};
  }

  void Session::selectBlockOutput(const Pane<Memory>& pane, std::size_t index, bool lines) {
    const auto output = blockOutput(pane, index);
    if (!output) {
      return;
    }

    const auto [first, last] = *output;
    const auto grid = copyGrid(pane.screen);
    const auto columns = static_cast<std::uint16_t>(grid.columns == 0 ? 0 : grid.columns - 1);
    const CopyPoint start{.x = 0, .y = first};
    if (features::terminal::copy_mode::select(copy_mode, pane.id, grid, {.cursor = lines ? CopyPoint{.x = columns, .y = last} : start, .anchor = start, .linewise = lines})) {
      changed_pane_ = pane.id;
      block_changed_ = true;
    }
  }

  void Session::copyBlockOutput(const Pane<Memory>& pane, std::size_t index) {
    const auto output = blockOutput(pane, index);
    if (!output) {
      return;
    }

    const auto [first, last] = *output;
    const auto columns = pane.screen.columns();

    link.send(CopySelection{.pane_id = pane.id, .start_x = 0, .start_y = first, .end_x = static_cast<std::uint16_t>(columns == 0 ? 0 : columns - 1), .end_y = last, .linewise = true});
  }

  void Session::copyBlockCommand(const Pane<Memory>& pane, std::size_t index) {
    const auto& block = pane.blocks[index];

    if (block.rows == 0 || block.command.empty()) {
      clipboard_.assign(block.command);
      clipboard_written_ = true;
      return;
    }

    // Enough of the command's start to find it past whatever a prompt left on its first row.
    constexpr std::size_t start_bytes = 16;
    const auto columns = pane.screen.columns();

    command_copy_.assign(block.command.substr(0, std::min(start_bytes, block.command.size())));
    command_copy_pane_ = pane.id;
    link.send(CopySelection{.pane_id = pane.id, .start_x = 0, .start_y = block.row, .end_x = static_cast<std::uint16_t>(columns == 0 ? 0 : columns - 1), .end_y = block.row + block.rows - 1U, .linewise = true});
  }

  bool Session::copyBlock(BlockAt block, BlockCopy what) {
    const auto [pane_id, index] = block;
    const auto* pane = findPane(pane_id);
    if (pane == nullptr || index >= pane->blocks.size()) {
      return false;
    }

    const bool copied = what == BlockCopy::command || blockOutput(*pane, index).hasValue();

    if (copied && what == BlockCopy::command) {
      copyBlockCommand(*pane, index);
    } else if (copied) {
      copyBlockOutput(*pane, index);
    }

    block_copy_ = {.pane_id = pane_id, .index = index, .what = what, .copied = copied, .serial = block_copy_.serial + 1};
    changed_pane_ = pane_id;
    block_changed_ = true;
    return copied;
  }

  const BlockCopyNote& Session::lastBlockCopy() const noexcept {
    return block_copy_;
  }

  void Session::stepBlockFromWindow(std::uint64_t pane_id, BlockStep direction) {
    stepBlock(pane_id, direction);
    if (auto* line = features::prompt::find(prompt_lines, pane_id); line != nullptr && features::prompt::selectedBlock(*line)) {
      features::prompt::selectBlock(*line, features::prompt::selectedBlock(*line), true);
    }
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

    // The prompt is looked for on the cursor's row and the rows right above it.
    constexpr std::size_t searched_rows = 8;
    const auto cursor = static_cast<std::size_t>(screen.cursor().y);

    for (std::size_t above = 0; above < searched_rows && above <= cursor; ++above) {
      const auto row = cursor - above;
      if ((screen.rowFlags(row) & static_cast<Byte>(RowFlag::prompt)) != 0) {
        return scroll.offset + static_cast<std::uint32_t>(row);
      }
    }

    return ds::none;
  }

}

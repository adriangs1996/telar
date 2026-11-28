module telar.gui.application;

import std;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.gui.features.prompt;
import telar.gui.features.notifications;
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

  std::uint32_t Session::blockMarks(const Pane<Memory>& pane, std::size_t index) noexcept {
    const auto key = blockKey(pane, index);
    std::uint32_t letters = 0;

    for (std::size_t letter = 0; letter < Pane<Memory>::mark_count; ++letter) {
      if (const auto& mark = pane.marks[letter]; mark && mark->block == key) {
        letters |= std::uint32_t{1} << letter;
      }
    }

    return letters;
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
    if (pane.folded.empty() && pane.inline_documents.empty() && !terminal::filter::indexOf(block_filter, pane)) {
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

    // The lines the filter of a block's output leaves out.
    terminal::filter::hide(block_filter, pane, spans);

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
    // The commands running before, a few being all a shell runs at once.
    constexpr std::size_t watched_running = 4;
    ds::Array<std::uint64_t, watched_running> running{};
    std::size_t running_count = 0;

    for (std::size_t index = 0; index < pane->blocks.size() && running_count < watched_running; ++index) {
      if (pane->blocks[index].state == CommandBlockState::running) {
        running.atMut(running_count++) = blockKey(*pane, index);
      }
    }

    pane->setBlocks(message.blocks);
    restoreBlock(*pane, selected);
    alertFinished(*pane, std::span{running}.first(running_count));

    // A command that ran without the shell finding it missing exists, though the shell never
    // reported it: a function defined since its last report, say.
    constexpr std::int32_t command_not_found = 127;

    if (!pane->blocks.empty() && !pane->shell.remote) {
      const auto& last = pane->blocks.back();
      if ((last.state == CommandBlockState::succeeded || last.state == CommandBlockState::failed) && last.status != command_not_found) {
        features::prompt::learn(prompt, pane->id, last.command, pane->shell.shell == IntegratedShell::fish ? shell::Dialect::fish : shell::Dialect::posix);
      }
    }

    restoreMarks(*pane);
    retainMarks(*pane);
    if (!pane->refold.empty()) {
      for (std::size_t at = 0; at < pane->refold.size(); ++at) {
        if (const auto index = pane->refold[at]; index < pane->blocks.size()) {
          pane->folded.push(blockKey(*pane, index));
        }
      }

      pane->refold.clear();
    }

    refreshFolds(*pane);
    followFilter(pane->id);
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
    } else if (markChord(pane_id, selection, {.pending = pending, .character = character}) || (pending != 0 && selection && blockChord(pending, {.pane_id = pane_id, .index = *selection}, character))) {
      return true;
    }

    if (character != '[' && character != ']' && character != '\'' && character != '`') {
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

  bool Session::markChord(std::uint64_t pane_id, ds::Option<std::size_t> selection, Chord chord) {
    const auto [pending, character] = chord;
    if ((pending != 'm' && pending != '\'' && pending != '`') || character < 'a' || character > 'z') {
      return false;
    }

    auto* pane = findPaneMut(pane_id);
    auto* line = features::prompt::find(prompt_lines, pane_id);
    if (pane == nullptr || line == nullptr || (pending == 'm' && !selection)) {
      return false;
    }

    auto& mark = pane->marks.atMut(static_cast<std::size_t>(character - 'a'));

    if (pending == 'm') {
      const auto key = blockKey(*pane, *selection);
      const auto top = jumpRow(*pane);

      mark = Pane<Memory>::BlockMark{.block = key, .offset = top > key ? top - key : 0};
      changed_pane_ = pane_id;
      block_changed_ = true;
      return true;
    }

    // A mark not set, or whose block is gone, goes nowhere.
    ds::Option<std::size_t> index;

    for (std::size_t at = 0; mark && at < pane->blocks.size(); ++at) {
      if (blockKey(*pane, at) == mark->block) {
        index = at;
        break;
      }
    }

    if (!index) {
      return true;
    }

    if (pending == '\'') {
      jumpToBlock(pane_id, *index);
      return true;
    }

    const auto row = mark->block + mark->offset - pane->scrollback_trimmed;

    recordJump(*pane, *line);
    features::prompt::selectBlock(*line, *index);
    scrollToShownRow(*pane, pane->folds.display(static_cast<std::uint32_t>(std::min<std::uint64_t>(row, std::numeric_limits<std::uint32_t>::max()))));
    return true;
  }

  void Session::retainMarks(Pane<Memory>& pane) noexcept {
    for (auto& mark : pane.marks.viewMut()) {
      if (mark && std::ranges::none_of(pane.blocks, [&](const CommandBlock& block) {
            return pane.scrollback_trimmed + block.row == mark->block;
          })) {
        mark.reset();
      }
    }
  }

  void Session::rememberMarks(Pane<Memory>& pane) noexcept {
    for (std::size_t letter = 0; letter < Pane<Memory>::mark_count; ++letter) {
      auto& mark = pane.marks.atMut(letter);

      pane.remark.atMut(letter).reset();
      for (std::size_t index = 0; mark && index < pane.blocks.size(); ++index) {
        if (blockKey(pane, index) == mark->block) {
          pane.remark.atMut(letter) = std::pair{index, mark->offset};
        }
      }

      mark.reset();
    }
  }

  void Session::restoreMarks(Pane<Memory>& pane) noexcept {
    for (std::size_t letter = 0; letter < Pane<Memory>::mark_count; ++letter) {
      if (const auto remembered = std::exchange(pane.remark.atMut(letter), ds::none); remembered && remembered->first < pane.blocks.size()) {
        pane.marks.atMut(letter) = Pane<Memory>::BlockMark{.block = blockKey(pane, remembered->first), .offset = remembered->second};
      }
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
    case 'm':
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
    case '&':
      static_cast<void>(openFilter(block));
      return true;
    case 'e':
      static_cast<void>(reuseBlock(block, BlockReuse::edit));
      return true;
    case 'E':
      static_cast<void>(reuseBlock(block, BlockReuse::edit_as_root));
      return true;
    case 'R':
      static_cast<void>(reuseBlock(block, BlockReuse::run));
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
    command_reuse_.reset();
    if (!readBlockCommand(pane, index)) {
      clipboard_.assign(pane.blocks[index].command);
      clipboard_written_ = true;
    }
  }

  bool Session::readBlockCommand(const Pane<Memory>& pane, std::size_t index) {
    const auto& block = pane.blocks[index];
    if (block.rows == 0 || block.command.empty()) {
      return false;
    }

    // Enough of the command's start to find it past whatever a prompt left on its first row.
    constexpr std::size_t start_bytes = 16;
    const auto columns = pane.screen.columns();

    command_copy_.assign(block.command.substr(0, std::min(start_bytes, block.command.size())));
    command_copy_pane_ = pane.id;
    command_copy_lines_ = std::size_t{block.lines} + 1;
    link.send(CopySelection{.pane_id = pane.id, .start_x = 0, .start_y = block.row, .end_x = static_cast<std::uint16_t>(columns == 0 ? 0 : columns - 1), .end_y = block.row + block.rows - 1U, .linewise = true});
    return true;
  }

  bool Session::reuseBlock(BlockAt block, BlockReuse how) {
    const auto [pane_id, index] = block;
    const auto* pane = findPane(pane_id);
    if (pane == nullptr || index >= pane->blocks.size() || pane->blocks[index].command.empty() || !prompt::edits(*this, pane_id)) {
      return false;
    }

    const auto& chosen = pane->blocks[index];
    const auto safe = wholeCommand(chosen) || how != BlockReuse::run ? how : BlockReuse::edit;

    if (!wholeCommand(chosen) && readBlockCommand(*pane, index)) {
      command_reuse_ = safe;
      return true;
    }

    // Copied out of the pane, which the editor's line must not view while it changes.
    const ds::String<Memory> command{memory, chosen.command};

    reuseCommand(pane_id, command, safe);
    return true;
  }

  bool Session::reuseRestored(std::uint64_t pane_id, std::size_t index, BlockReuse how) {
    const auto* pane = findPane(pane_id);
    if (pane == nullptr || index >= pane->restored.size() || pane->restored[index].command.empty() || !prompt::edits(*this, pane_id)) {
      return false;
    }

    // Its rows went with the runtime that ran it: a command it holds cut short only goes to the
    // editor, as it is.
    const auto& chosen = pane->restored[index];
    const ds::String<Memory> command{memory, chosen.command};

    reuseCommand(pane_id, command, wholeCommand(chosen) || how != BlockReuse::run ? how : BlockReuse::edit);
    return true;
  }

  bool Session::wholeCommand(const CommandBlock& block) noexcept {
    // A block carries its command's first line, cut at a character's boundary short of the
    // limit: one with more lines, or near the limit, may have been cut.
    constexpr std::size_t longest_character = 4;

    return block.lines == 0 && block.command.size() + longest_character <= max_block_command_bytes;
  }

  void Session::reuseCommand(std::uint64_t pane_id, std::string_view command, BlockReuse how) {
    constexpr std::string_view root = "sudo ";
    ds::String<Memory> text{memory};

    // The rows a command was read from end in a line break, and may hold spaces after it.
    while (!command.empty() && (command.back() == '\n' || command.back() == '\r' || command.back() == ' ')) {
      command.remove_suffix(1);
    }

    if (how == BlockReuse::edit_as_root && !command.starts_with(root)) {
      text.append(root);
    }

    text.append(command);
    selectBlock(pane_id, ds::none);
    prompt::write(*this, pane_id, text);
    if (how == BlockReuse::run) {
      static_cast<void>(prompt::key(*this, pane_id, prompt::KeyPress{.key = prompt::Key::enter}));
    }

    changed_pane_ = pane_id;
  }

  bool Session::copyBlock(BlockAt block, BlockCopy what) {
    const auto [pane_id, index] = block;
    const auto* pane = findPane(pane_id);
    if (pane == nullptr || index >= pane->blocks.size()) {
      return false;
    }

    // Output no command printed has no command to copy.
    const bool copied = what == BlockCopy::command ? !pane->blocks[index].command.empty() : blockOutput(*pane, index).hasValue();

    // A filtered output copies the lines the filter shows.
    if (copied && what == BlockCopy::command) {
      copyBlockCommand(*pane, index);
    } else if (copied && !copyFiltered(block)) {
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

  void Session::windowActivated(bool active) noexcept {
    window_active_ = active;
  }

  void Session::alertFinished(const Pane<Memory>& pane, std::span<const std::uint64_t> running) {
    if (running.empty() || !configuration.long_commands.enabled) {
      return;
    }

    const bool watched = window_active_ && notifications::targetVisible(*this, {.kind = NotificationTarget::Kind::pane, .id = pane.id});

    for (std::size_t index = 0; index < pane.blocks.size(); ++index) {
      const auto& block = pane.blocks[index];
      const bool ended = block.state == CommandBlockState::succeeded || block.state == CommandBlockState::failed;
      if (!ended || std::ranges::find(running, blockKey(pane, index)) == running.end()) {
        continue;
      }

      const features::notifications::FinishedCommand finished{.pane_id = pane.id, .command = block.command, .failed = block.state == CommandBlockState::failed, .status = block.status, .duration_ms = block.duration_ms};
      if (features::notifications::CommandAlerts::alerts(configuration.long_commands, finished, watched)) {
        features::notifications::CommandAlerts::Message message;

        notifications::publish(*this, features::notifications::CommandAlerts::input(finished, message), now_());
      }
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

  std::uint64_t Session::liveFrom(const Pane<Memory>& pane) noexcept {
    const auto& blocks = pane.blocks;
    if (blocks.empty()) {
      return 0;
    }

    // Output no command printed starts on the row a prompt was drawn on before a job's report
    // wrote over it: that row is the output's, not the live prompt's.
    const auto& last = blocks.back();

    return static_cast<std::uint64_t>(last.row) + std::max<std::uint32_t>(last.rows, last.state == CommandBlockState::background ? 1 : 0);
  }

  ds::Option<std::uint32_t> Session::livePromptRow(const Pane<Memory>& pane) {
    const auto& screen = pane.screen;
    const auto& scroll = screen.scroll();
    if (static_cast<std::uint64_t>(scroll.offset) + screen.rows() < scroll.total_rows) {
      return ds::none;
    }

    // The prompt is looked for from the cursor's row up, however many rows a prompt and the
    // command typed at it take, and no higher than the last command's own rows: above them is
    // output, and a prompt there is a command's, not the live one.
    // After output no command printed, the shell drew its prompt again without saying so: the
    // live prompt is on the cursor's row when no row says it is a prompt.
    const auto& blocks = pane.blocks;
    const bool background = !blocks.empty() && blocks.back().state == CommandBlockState::background;
    const auto live_from = liveFrom(pane);
    const auto first = static_cast<std::size_t>(live_from > scroll.offset ? live_from - scroll.offset : 0);
    const auto end = std::min(static_cast<std::size_t>(screen.cursor().y) + 1, static_cast<std::size_t>(screen.rows()));

    for (auto row = end; row-- > first;) {
      if ((screen.rowFlags(row) & static_cast<Byte>(RowFlag::prompt)) != 0) {
        return scroll.offset + static_cast<std::uint32_t>(row);
      }
    }

    if (background && end > first) {
      return scroll.offset + static_cast<std::uint32_t>(end - 1);
    }

    return ds::none;
  }

}

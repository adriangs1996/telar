module telar.gui.application;

import std;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.tbc;
import telar.gui.features.terminal.graphics;
import telar.base.memory.allocators;

namespace telar::gui::application {

  namespace {

    // A tab's application when nothing names one.
    constexpr std::string_view fallback_application = "shell";

    // The bytes of a block's text: its command, directory, host, user and branch.
    std::size_t textBytes(const CommandBlock& block) noexcept {
      return block.command.size() + block.directory.size() + block.host.size() + block.user.size() + block.branch.size();
    }

    template <Allocator Memory>
    void appendText(ds::String<Memory>& text, const CommandBlock& block) {
      text.append(block.command);
      text.append(block.directory);
      text.append(block.host);
      text.append(block.user);
      text.append(block.branch);
    }

    // Points each block's text at `text`, which holds it in order from `start`.
    void bindText(std::span<CommandBlock> blocks, std::string_view text, std::size_t start = 0) {
      const auto take = [&](std::string_view& field) {
        const auto length = field.size();

        field = text.substr(start, length);
        start += length;
      };

      for (auto& block : blocks) {
        take(block.command);
        take(block.directory);
        take(block.host);
        take(block.user);
        take(block.branch);
      }
    }

  }

  template <Allocator Memory>
  Pane<Memory>::Pane(Memory& memory, std::uint64_t identity, features::terminal::graphics::GraphicsBudget& budget)
      : id(identity),
        screen(memory),
        rows(memory),
        graphics(memory, budget),
        title(memory),
        cwd(memory),
        foreground(memory),
        document(memory),
        document_parts(memory),
        inline_documents(memory),
        git_branch(memory),
        shell_host(memory),
        shell_directory(memory),
        blocks(memory),
        blocks_text(memory),
        restored(memory),
        restored_text(memory),
        folded(memory),
        folds(memory),
        refold(memory) {}

  template <Allocator Memory>
  void Pane<Memory>::setGit(const PaneGit& message) {
    auto kept = message;

    git_branch.assign(message.branch);
    kept.branch = git_branch.view();
    git = kept;
  }

  template <Allocator Memory>
  tbc::val_static<PaneShell> Pane<Memory>::setShell(const PaneShell& message) {
    auto previous = shell;
    auto kept = message;

    previous.host = {};
    previous.directory = {};
    shell_host.assign(message.host);
    shell_directory.assign(message.directory);
    kept.host = shell_host.view();
    kept.directory = shell_directory.view();
    shell = kept;
    return previous;
  }

  template <Allocator Memory>
  void Pane<Memory>::setBlocks(std::span<const CommandBlock> commands) {
    // The blocks an earlier runtime kept come first and have no rows: they are kept apart.
    std::size_t restored_count = 0;

    while (restored_count < commands.size() && commands[restored_count].restored) {
      ++restored_count;
    }

    std::size_t restored_bytes = 0;

    for (const auto& block : commands.first(restored_count)) {
      restored_bytes += textBytes(block);
    }

    restored.clear();
    restored_text.clear();
    restored_text.reserve(restored_bytes);
    for (const auto& block : commands.first(restored_count)) {
      appendText(restored_text, block);
    }

    restored.extend(commands.first(restored_count));
    bindText(restored.viewMut(), restored_text.view());

    const auto live = commands.subspan(restored_count);
    // The blocks older than the first the runtime sends, ended, stay; the oldest go past the
    // limit. Nothing sent is a cleared scrollback, which keeps none.
    std::size_t older = 0;

    if (!live.empty()) {
      const auto first = live.front().row;

      while (older < blocks.size() && blocks[older].row < first && blocks[older].state != CommandBlockState::running && blocks[older].state != CommandBlockState::session) {
        ++older;
      }
    }

    const auto room = blocks_kept_limit - std::min(blocks_kept_limit, live.size());
    const auto kept_from = older - std::min(older, room);
    // The kept blocks' text follows one another's, which may come after dropped blocks' text.
    const auto [text_first, text_end] = textOf(kept_from, older);

    // They stay at the text's start; the pane's own copy of the new text follows, so no block
    // views text that moves.
    blocks_text.truncate(text_end);
    blocks_text.remove(0, text_first);
    blocks.truncate(older);

    std::size_t position = 0;

    static_cast<void>(blocks.retain([&position, kept_from](const CommandBlock&) {
      return position++ >= kept_from;
    }));

    std::size_t bytes = 0;

    for (const auto& block : live) {
      bytes += textBytes(block);
    }

    // A restored block the runtime sent out of its place has no rows to stand on here.
    blocks_text.reserve(blocks_text.size() + bytes);
    for (const auto& block : live) {
      if (!block.restored) {
        appendText(blocks_text, block);
      }
    }

    blocks.extend(live);
    static_cast<void>(blocks.retain([](const CommandBlock& block) {
      return !block.restored;
    }));

    kept_blocks = older - kept_from;
    bindText(blocks.viewMut(), blocks_text.view());
  }

  template <Allocator Memory>
  std::pair<std::size_t, std::size_t> Pane<Memory>::textOf(std::size_t first, std::size_t end) const noexcept {
    if (first >= end) {
      return {0, 0};
    }

    const auto* base = blocks_text.view().data();
    const auto& last = blocks[end - 1].branch;

    return {static_cast<std::size_t>(blocks[first].command.data() - base), static_cast<std::size_t>(last.data() - base) + last.size()};
  }

  template <Allocator Memory>
  void Pane<Memory>::forgetKeptBlocks() {
    std::size_t position = 0;
    const auto text_end = textOf(0, kept_blocks).second;

    static_cast<void>(blocks.retain([&position, kept = kept_blocks](const CommandBlock&) {
      return position++ >= kept;
    }));

    blocks_text.remove(0, text_end);
    kept_blocks = 0;
    bindText(blocks.viewMut(), blocks_text.view());
  }

  template <Allocator Memory>
  Pane<Memory>::InlineDocument::InlineDocument(Memory& memory, std::uint64_t identity)
      : id(identity),
        document(memory),
        parts(memory) {}

  template <Allocator Memory>
  tbc::val_a<std::string_view> tabApplicationName(tbc::ref_a<Tab<Memory>> tab, tbc::val_a<std::type_identity_t<const Pane<Memory>*>> pane) noexcept {
    if (pane != nullptr) {
      if (!pane->foreground.empty()) {
        return pane->foreground;
      }

      if (pane->id != tab.foreground_pane) {
        return fallback_application;
      }
    }

    return tab.foreground.empty() ? fallback_application : std::string_view{tab.foreground};
  }

  template struct Pane<Memory>;
  template std::string_view tabApplicationName<Memory>(const Tab<Memory>& tab, const Pane<Memory>* pane) noexcept;

}

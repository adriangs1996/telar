module telar.gui.application;

import std;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.tbc;
import telar.gui.features.terminal.graphics;
import telar.base.memory.allocators;

namespace telar::gui::application {

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
    std::size_t bytes = 0;

    for (const auto& block : commands) {
      bytes += block.command.size();
    }

    // The pane's own copy of the lines comes first, so no command views it while it grows.
    blocks_text.clear();
    blocks_text.reserve(bytes);
    for (const auto& block : commands) {
      blocks_text.append(block.command);
    }

    blocks.clear();
    blocks.extend(commands);

    std::size_t start = 0;

    for (auto& block : blocks.viewMut()) {
      const auto size = block.command.size();

      block.command = blocks_text.view().substr(start, size);
      start += size;
    }
  }

  template <Allocator Memory>
  Pane<Memory>::InlineDocument::InlineDocument(Memory& memory, std::uint64_t identity)
      : id(identity),
        document(memory),
        parts(memory) {}

  template <Allocator Memory>
  tbc::val_a<std::string_view> tabApplicationName(tbc::ref_a<Tab<Memory>> tab, tbc::val_a<std::type_identity_t<const Pane<Memory>*>> pane) noexcept {
    constexpr std::string_view fallback = "shell";

    if (pane != nullptr) {
      if (!pane->foreground.empty()) {
        return pane->foreground;
      }

      if (pane->id != tab.foreground_pane) {
        return fallback;
      }
    }

    return tab.foreground.empty() ? fallback : std::string_view{tab.foreground};
  }

  template struct Pane<Memory>;
  template std::string_view tabApplicationName<Memory>(const Tab<Memory>& tab, const Pane<Memory>* pane) noexcept;

}

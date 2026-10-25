#pragma once

#include "../model/client_layouts.hpp"
#include "../runtime/pane_service.hpp"
#include "reader.hpp"

namespace telar::runtime::checkpoint {

template <Allocator Memory, EventLoop Poller, HistoryEventSink History = DiscardedHistory>
class Restore {
public:
  explicit Restore(Memory &memory, RuntimeModel<Memory> &model, PaneService<Memory, Poller, History> &panes, ClientLayouts<Memory> &layouts, bool resume_agents)
      : memory_(memory),
        model_(model),
        panes_(panes),
        layouts_(layouts),
        resume_agents_(resume_agents) {}

  void apply(std::span<const Byte> bytes) {
    Reader reader{bytes};
    model_.next_pane_generation = std::max(model_.next_pane_generation, reader.counters.generation);
    std::array<PaneRecord, 256> records;
    std::size_t count = 0;
    reader.read([&]<typename Record>(const Record &record) {
      if constexpr (std::same_as<Record, PaneRecord>) {
        records[count++] = record;
      } else if constexpr (!std::same_as<Record, LayoutRecord>) {
        try {
          restore(record);
        } catch (const std::exception &) {
        }
      }
    });

    const auto panes = std::span{records}.first(count);
    std::ranges::sort(panes, {}, &PaneRecord::id);
    for (const auto &record : panes) {
      try {
        restore(record);
      } catch (const std::exception &) {
      }
    }

    model_.panes.advanceCounter(reader.counters.pane);
    model_.workspaces.advanceCounter(reader.counters.workspace);
    advanceIdentityCounter(model_.next_tab_id, reader.counters.tab);
    dropEmptyTabs();

    Reader layouts{bytes};
    layouts.read([&]<typename Record>(const Record &record) {
      if constexpr (std::same_as<Record, LayoutRecord>) {
        try {
          std::array<Byte, 64 * 1024> scratch;
          DecodeStorage storage{scratch};
          layouts_.retain(record.identity, Codec::decode<UpdateClientLayout>(record.payload, storage));
        } catch (const std::exception &) {
        }
      }
    });

    ++model_.workspace_revision;
  }

private:
  static void validateIdentity(std::uint64_t identity) {
    if (identity == 0) {
      throw EncodingError{"Invalid restored identity"};
    }
  }

  void restore(const WorkspaceRecord &record) {
    validateIdentity(record.id);
    validateIdentity(record.first_tab);
    auto workspace = makeOwned<Workspace<Memory>>(memory_, memory_, record.id, record.path, record.name);
    workspace->tabs.emplace_back(memory_, record.first_tab, record.first_label);
    model_.workspaces.insert(record.id, std::move(workspace));
    advanceIdentityCounter(model_.next_tab_id, record.first_tab + 1);
  }

  void restore(const TabRecord &record) {
    validateIdentity(record.id);
    auto *workspace = model_.workspaces.find(record.workspace);
    if (workspace == nullptr || workspace->tabs.size() == 64 || workspace->tab(record.id) != nullptr) {
      return;
    }

    workspace->tabs.emplace_back(memory_, record.id, record.label);
    advanceIdentityCounter(model_.next_tab_id, record.id + 1);
  }

  void restore(const WorktreeRecord &record) {
    const auto registered = model_.worktrees.registerEntry(record.registration, record.id);
    if (record.workspace != 0) {
      model_.worktrees.find(registered.worktree)->workspace = record.workspace;
    }
  }

  void restore(const PaneRecord &record) {
    validateIdentity(record.id);
    auto *workspace = model_.workspaces.find(record.workspace);
    auto *tab = workspace == nullptr ? nullptr : workspace->tab(record.tab);
    if (tab == nullptr || tab->panes.size() == 64 || model_.panes.find(record.id) != nullptr) {
      return;
    }

    std::array<std::string_view, 64> original;
    auto remaining = record.arguments;
    for (std::size_t index = 0; index < record.argument_count; ++index) {
      const auto end = remaining.find('\0');
      original[index] = remaining.substr(0, end);
      remaining.remove_prefix(end + 1);
    }

    std::optional<AgentResume> resume = resumable(record);
    std::array<std::string_view, 4> resume_storage;
    auto resumed = resume ? resumeArguments(*resume, resume_storage) : std::span<const std::string_view>{};
    const bool direct = !resumed.empty() && original[0].substr(original[0].rfind('/') + 1) == resumed[0];
    if (direct) {
      resume_storage[0] = original[0];
    }

    const auto arguments = direct ? resumed : std::span<const std::string_view>{original}.first(record.argument_count);
    Command command{memory_, Launch{.cwd = record.cwd, .arguments = arguments}};
    const TerminalSize size{.cols = record.columns == 0 ? std::uint16_t{80} : record.columns, .rows = record.rows == 0 ? std::uint16_t{24} : record.rows, .cell_width_px = 0, .cell_height_px = 0};
    auto &pane = panes_.launch(command, TabLocation{.workspace = {.id = record.workspace}, .tab_id = record.tab}, size, record.id);
    tab->panes.push_back(pane.id);
    pane.launch.restore(record.arguments, record.argument_count);
    pane.restored_agent = resume;

    if (resume && !direct) {
      for (std::size_t index = 0; index < resumed.size(); ++index) {
        const Byte separator = index == 0 ? 0 : ' ';
        if (index != 0) {
          pane.input.append({&separator, 1});
        }
        pane.input.append({reinterpret_cast<const Byte *>(resumed[index].data()), resumed[index].size()});
      }
      constexpr Byte enter = '\r';
      pane.input.append({&enter, 1});
      panes_.flushInput(pane);
    }
  }

  std::optional<AgentResume> resumable(const PaneRecord &record) const {
    if (!resume_agents_ || !validResumeSession(record.provider, record.session)) {
      return std::nullopt;
    }

    for (const auto *pane : model_.panes.items()) {
      if (pane != nullptr && pane->restored_agent && pane->restored_agent->provider == record.provider && pane->restored_agent->session.view() == record.session) {
        return std::nullopt;
      }
    }

    AgentResume resume{.provider = record.provider, .title_source = record.title_source, .in_pane = record.in_pane};
    resume.session.assign(record.session);
    resume.title.assign(record.title);
    return resume;
  }

  void dropEmptyTabs() {
    for (auto *workspace : model_.workspaces.items()) {
      if (workspace == nullptr) {
        continue;
      }

      std::erase_if(workspace->tabs, [](const auto &tab) { return tab.panes.empty(); });
      if (workspace->tabs.empty()) {
        model_.workspaces.erase(workspace->id);
      }
    }

    for (auto *worktree : model_.worktrees.items()) {
      if (worktree != nullptr && worktree->workspace && model_.workspaces.find(*worktree->workspace) == nullptr) {
        worktree->workspace.reset();
      }
    }
  }

  Memory &memory_;
  RuntimeModel<Memory> &model_;
  PaneService<Memory, Poller, History> &panes_;
  ClientLayouts<Memory> &layouts_;
  bool resume_agents_;
};

}

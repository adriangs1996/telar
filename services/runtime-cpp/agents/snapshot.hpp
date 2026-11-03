#pragma once

#include "../model/runtime_model.hpp"
#include "registry.hpp"
#include "telar_config/agents/provider.hpp"
#include <cstring>

namespace telar::runtime {

template <Allocator Memory>
class AgentSnapshotBuilder {
public:
  void publish(ClientSession<Memory> &client, const RuntimeModel<Memory> &model, const AgentRegistry<Memory> &registry) {
    auto &entries = entries_;
    auto &directories = directories_;
    auto &placeholders = placeholders_;
    std::size_t count = 0;
    const auto now = wallMilliseconds();
    for (const auto &agent : registry.records()) {
      const auto *pane = model.panes.find(agent->pane);
      if (pane == nullptr || pane->generation != agent->generation || agent->sequence == 0) {
        continue;
      }
      const auto *workspace = model.workspaces.find(pane->location.workspace.id);
      const auto *tab = workspace == nullptr ? nullptr : workspace->tab(pane->location.tab_id);
      if (tab == nullptr) {
        continue;
      }
      const auto position = std::find(tab->panes.begin(), tab->panes.end(), pane->id);
      if (position == tab->panes.end()) {
        continue;
      }

      auto provider = describeProvider(agent->provider);
      const auto *manifest = model.manifests.find(agent->provider);
      if (manifest != nullptr) {
        provider = {manifest->name.view(), manifest->displayName(), manifest->placeholderTitle(placeholders[count]), manifest->attachments};
      }
      std::string_view cwd = pane->cwd;
      const char *home = std::getenv("HOME");
      if (home != nullptr && cwd.starts_with(home) && (cwd.size() == std::strlen(home) || cwd[std::strlen(home)] == '/')) {
        std::array<char, 48> shortened{'~'};
        const auto suffix = utf8Prefix(cwd.substr(std::strlen(home)), 47);
        std::copy(suffix.begin(), suffix.end(), shortened.begin() + 1);
        directories[count].assign({shortened.data(), suffix.size() + 1});
      } else {
        directories[count].assign(utf8Prefix(cwd, 48));
      }

      entries[count] = {
          .pane_id = pane->id,
          .pane_generation = pane->generation,
          .location = pane->location,
          .pane_index = static_cast<std::uint16_t>(position - tab->panes.begin() + 1),
          .process_id = static_cast<std::uint32_t>(agent->process_identity ? agent->process_identity->pid : pane->process->processId()),
          .session_id = agent->session_id,
          .workspace_label = utf8Prefix(workspace->displayName(), 48),
          .tab_label = tab->label,
          .session_title = agent->title_source == AgentTitleSource::telar && !pane->terminal.effects.title().empty() ? utf8Prefix(pane->terminal.effects.title(), 96) : agent->title.view().empty() ? provider.placeholder
                                                                                                                                                                                                    : agent->title.view(),
          .title_source = agent->title_source == AgentTitleSource::telar && !pane->terminal.effects.title().empty() ? AgentTitleSource::terminal : agent->title_source,
          .title_state = agent->title_state,
          .cwd_label = directories[count].view(),
          .provider = agent->provider,
          .provider_name = provider.name,
          .display_name = provider.display_name,
          .icon = manifest != nullptr ? manifest->icon.view() : std::string_view{},
          .attachments = provider.attachments,
          .status = agent->status,
          .blocked_reason = agent->blocked_reason,
          .last_event = agent->event.view(),
          .status_age_s = static_cast<std::uint32_t>(std::clamp<std::int64_t>((now - agent->changed_at) / 1000, 0, UINT32_MAX)),
          .source = agent->source,
          .authority = agent->authority,
          .confidence = agent->confidence,
          .sequence = agent->sequence,
          .observed_at_ms = agent->observed_at,
          .expires_at_ms = agent->expires_at,
          .work_tree = agent->worktree,
          .final_message = agent->progress.final_message.view(),
          .plan_done = agent->progress.done(),
          .plan_total = agent->progress.total(),
          .plan_step = agent->progress.step(),
      };
      ++count;
    }

    client.connection.send(AgentSnapshot{registry.revision() + model.workspace_revision, std::span{entries}.first(count)});
    client.agent_revision = registry.revision();
    client.agent_workspace_revision = model.workspace_revision;
  }

private:
  std::array<AgentSnapshotEntry, AgentRegistry<Memory>::capacity> entries_;
  std::array<FixedText<48>, AgentRegistry<Memory>::capacity> directories_;
  std::array<FixedText<96>, AgentRegistry<Memory>::capacity> placeholders_;
};

}

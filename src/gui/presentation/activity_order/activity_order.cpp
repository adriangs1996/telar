module telar.gui.presentation.activity_order;

import std;
import telar.tbc;

namespace telar::gui {

  auto AgentOrder::Plan::view() const noexcept -> std::span<const Entry> {
    return std::span{entries}.first(count);
  }

  auto AgentOrder::attention(AgentStatus status) noexcept -> Attention {
    switch (status) {
    case AgentStatus::blocked:
    case AgentStatus::failed:
      return Attention::needs_input;
    case AgentStatus::working:
      return Attention::working;
    case AgentStatus::done:
      return Attention::done;
    case AgentStatus::ready:
      return Attention::ready;
    default:
      return Attention::unknown;
    }
  }

  bool AgentOrder::stacked(AgentStatus status) noexcept {
    const auto group = attention(status);

    return group == Attention::needs_input || group == Attention::working;
  }

  template <Allocator Memory>
  tbc::view<const Worktree<Memory>*, tbc::lt::a> AgentOrder::taskRow(tbc::view<const WorkspaceReplica<Memory>&, tbc::lt::a> workspaces, const Agent<Memory>& agent) noexcept {
    if (const auto* row = workspaces.worktree(agent.work_tree)) {
      return row;
    }

    return agent.location.workspace.kind == WorkspaceLocation::Kind::workspace ? workspaces.worktreeOfWorkspace(agent.location.workspace.id) : nullptr;
  }

  template <Allocator Memory>
  auto AgentOrder::priority(const Agent<Memory>& agent) noexcept -> Priority {
    return std::tuple{attention(agent.status), agent.status_age_s, agent.pane_id, agent.pane_generation};
  }

  template <Allocator Memory>
  auto AgentOrder::arrange(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory>& workspaces) noexcept -> Plan {
    Plan plan;

    plan.count = std::min(agents.size(), maximum_agents);
    const auto entries = std::span{plan.entries}.first(plan.count);

    for (std::size_t index = 0; index < plan.count; ++index) {
      const auto& agent = agents[index];
      const auto card = taskRow(workspaces, agent) != nullptr ? ActivityCard::task : ActivityCard::agent;
      const auto project = projectOf(workspaces, agent);

      entries[index] = {.agent = index, .project = project, .card = card};
    }

    for (auto& entry : entries) {
      entry.creator = creatorOf(agents, workspaces, entries, entry);
    }

    std::ranges::sort(entries, [&](const Entry& left, const Entry& right) {
      return lessThan(agents, workspaces, left, right);
    });

    for (std::size_t index = 0; index < entries.size(); ++index) {
      entries[index].first_in_project = index == 0 || entries[index].project != entries[index - 1].project;
    }

    return plan;
  }

  template <Allocator Memory>
  std::size_t AgentOrder::projectRank(std::optional<std::uint64_t> identity, std::span<const Workspace<Memory>> workspaces) noexcept {
    if (identity) {
      for (std::size_t index = 0; index < workspaces.size(); ++index) {
        if (workspaces[index].location.kind == WorkspaceLocation::Kind::workspace && *identity == workspaces[index].location.id) {
          return index;
        }
      }
    }

    return unknown_project;
  }

  template <Allocator Memory>
  std::optional<std::uint64_t> AgentOrder::projectOf(const WorkspaceReplica<Memory>& workspaces, const Agent<Memory>& agent) noexcept {
    if (const auto* row = workspaces.worktree(agent.work_tree)) {
      return row->source;
    }

    if (agent.location.workspace.kind != WorkspaceLocation::Kind::workspace) {
      return std::nullopt;
    }

    const auto project = workspaces.projectOf(agent.location.workspace.id);

    return workspaces.indexOf(project) < workspaces.entries().size() ? std::optional{project} : std::nullopt;
  }

  template <Allocator Memory>
  std::optional<std::size_t> AgentOrder::creatorOf(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory>& workspaces, std::span<const Entry> entries, const Entry& entry) noexcept {
    const auto* row = entry.card == ActivityCard::agent ? nullptr : taskRow(workspaces, agents[entry.agent]);
    if (row == nullptr) {
      return std::nullopt;
    }

    for (const auto& candidate : entries) {
      const auto& parent = agents[candidate.agent];

      if (candidate.agent == entry.agent || candidate.card != ActivityCard::agent || candidate.project != entry.project) {
        continue;
      }

      if (row->coordinator) {
        const auto& reference = *row->coordinator;
        if (parent.pane_id == reference.pane_id && parent.pane_generation == reference.pane_generation && parent.session_id == reference.session_id) {
          return candidate.agent;
        }
      } else if (row->created_by == parent.pane_id) {
        return candidate.agent;
      }
    }

    return std::nullopt;
  }

  template <Allocator Memory>
  bool AgentOrder::lessThan(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory>& workspaces, const Entry& left, const Entry& right) noexcept {
    const auto rows = std::span<const Workspace<Memory>>{workspaces.entries()};
    const auto left_rank = projectRank(left.project, rows);
    const auto right_rank = projectRank(right.project, rows);
    if (left_rank != right_rank) {
      return left_rank < right_rank;
    }

    const auto left_orphan = left.card != ActivityCard::agent && !left.creator;
    const auto right_orphan = right.card != ActivityCard::agent && !right.creator;
    if (left_orphan != right_orphan) {
      return !left_orphan;
    }

    if (!left_orphan) {
      const auto left_root = left.creator.value_or(left.agent);
      const auto right_root = right.creator.value_or(right.agent);
      if (left_root != right_root) {
        return priority(agents[left_root]) < priority(agents[right_root]);
      }

      if ((left.card == ActivityCard::agent) != (right.card == ActivityCard::agent)) {
        return left.card == ActivityCard::agent;
      }
    }

    return priority(agents[left.agent]) < priority(agents[right.agent]);
  }

  template <Allocator Memory>
  auto ActivityOrder<Memory>::Plan::view() const noexcept -> std::span<const Entry> {
    return std::span{entries}.first(count);
  }

  template <Allocator Memory>
  void ActivityOrder<Memory>::write(std::span<const Source> sources, std::uint8_t active_slot, Plan& output) {
    if (sources.size() > maximum_sources) {
      throw std::length_error{"TooManyActivitySources"};
    }

    ActivityOrder order{sources, output};

    order.collect(active_slot);
    order.findParents();
    order.breakCycles();
    order.emitForest();
  }

  template <Allocator Memory>
  ActivityOrder<Memory>::ActivityOrder(std::span<const Source> sources, Plan& output)
      : sources_(sources),
        output_(output) {}

  template <Allocator Memory>
  void ActivityOrder<Memory>::collect(std::uint8_t active_slot) {
    for (std::size_t source_index = 0; source_index < sources_.size(); ++source_index) {
      const auto& source = sources_[source_index];
      if (source.agents.size() > AgentOrder::maximum_agents) {
        throw std::length_error{"TooManyAgents"};
      }

      // Another machine's row in the sidebar stacks its working agents, so its cards here are
      // only the agents that wait on the person; its tracked commands stay on that machine.
      const bool active = source.slot == active_slot;
      const auto fleet = AgentOrder::arrange(source.agents, source.workspaces);
      const auto& worktrees = source.workspaces.worktrees();
      std::array<bool, WorkspaceReplica<Memory>::maximum_worktrees> represented{};

      for (const auto& entry : fleet.view()) {
        if (!active && AgentOrder::attention(source.agents[entry.agent].status) != AgentOrder::Attention::needs_input) {
          continue;
        }

        auto& node = nodes_[count_++];

        node = {.source = source_index, .agent = entry.agent, .project = entry.project, .card = entry.card};
        if (const auto* row = AgentOrder::taskRow(source.workspaces, source.agents[entry.agent])) {
          const auto index = static_cast<std::size_t>(row - worktrees.data());

          node.worktree = index;
          represented[index] = true;
        }
      }

      for (std::size_t index = 0; index < worktrees.size() && active; ++index) {
        const auto& row = worktrees[index];
        if (!represented[index] && row.command_state != CommandState::none) {
          nodes_[count_++] = {.source = source_index, .worktree = index, .project = row.source, .card = ActivityCard::task};
        }
      }
    }
  }

  template <Allocator Memory>
  auto ActivityOrder<Memory>::identityAt(std::size_t index) const noexcept {
    const auto& node = nodes_[index];
    if (!node.agent) {
      std::terminate();
    }

    const auto& agent = sources_[node.source].agents[*node.agent];

    return std::tuple{agent.session_id, agent.pane_id, agent.pane_generation};
  }

  template <Allocator Memory>
  const Worktree<Memory>* ActivityOrder<Memory>::rowOf(const Entry& entry) const noexcept {
    const auto& source = sources_[entry.source];

    if (entry.worktree) {
      return &source.workspaces.worktrees()[*entry.worktree];
    }

    return entry.agent ? AgentOrder::taskRow(source.workspaces, source.agents[*entry.agent]) : nullptr;
  }

  template <Allocator Memory>
  std::optional<std::size_t> ActivityOrder<Memory>::parentOf(std::span<const std::size_t> agents, std::size_t index) const noexcept {
    const auto& entry = nodes_[index];
    const auto* row = rowOf(entry);
    if (row == nullptr) {
      return std::nullopt;
    }

    if (row->coordinator) {
      const auto& reference = *row->coordinator;
      const auto target = std::tuple{reference.session_id, reference.pane_id, reference.pane_generation};
      auto candidate = std::ranges::lower_bound(agents, target, {}, [this](std::size_t agent) {
        return identityAt(agent);
      });

      while (candidate != agents.end() && identityAt(*candidate) == target) {
        if (*candidate != index) {
          return *candidate;
        }

        ++candidate;
      }

      return std::nullopt;
    }

    if (!row->created_by) {
      return std::nullopt;
    }

    std::size_t start = index;

    while (start != 0 && nodes_[start - 1].source == entry.source) {
      --start;
    }

    for (std::size_t parent = start; parent < count_ && nodes_[parent].source == entry.source; ++parent) {
      const auto& candidate = nodes_[parent];
      if (candidate.agent && parent != index && candidate.card == ActivityCard::agent && candidate.project == entry.project && sources_[entry.source].agents[*candidate.agent].pane_id == *row->created_by) {
        return parent;
      }
    }

    return std::nullopt;
  }

  template <Allocator Memory>
  void ActivityOrder<Memory>::findParents() {
    std::array<std::size_t, maximum_entries> agents{};
    std::size_t agent_count = 0;

    for (std::size_t index = 0; index < count_; ++index) {
      if (nodes_[index].agent) {
        agents[agent_count++] = index;
      }
    }

    const auto indices = std::span{agents}.first(agent_count);

    std::ranges::sort(indices, [this](std::size_t left, std::size_t right) {
      return std::tuple{identityAt(left), left} < std::tuple{identityAt(right), right};
    });

    for (std::size_t index = 0; index < count_; ++index) {
      nodes_[index].parent = parentOf(indices, index);
    }
  }

  template <Allocator Memory>
  void ActivityOrder<Memory>::breakChainCycle(std::size_t start, std::span<Visit> visits, std::span<std::size_t> path) noexcept {
    std::size_t path_length = 0;
    std::optional<std::size_t> current{start};

    while (current) {
      const auto index = *current;
      if (visits[index] != Visit::unseen) {
        if (visits[index] == Visit::visiting) {
          nodes_[index].parent.reset();
        }

        break;
      }

      visits[index] = Visit::visiting;
      path[path_length++] = index;
      current = nodes_[index].parent;
    }

    for (const auto index : path.first(path_length)) {
      visits[index] = Visit::finished;
    }
  }

  template <Allocator Memory>
  void ActivityOrder<Memory>::breakCycles() noexcept {
    std::array<Visit, maximum_entries> visits{};
    std::array<std::size_t, maximum_entries> path{};

    for (std::size_t start = 0; start < count_; ++start) {
      if (visits[start] != Visit::finished) {
        breakChainCycle(start, visits, path);
      }
    }
  }

  template <Allocator Memory>
  auto ActivityOrder<Memory>::linkChildren() noexcept -> Children {
    Children children;

    for (std::size_t index = 0; index < count_; ++index) {
      if (const auto parent = nodes_[index].parent) {
        nodes_[*parent].coordinator = true;
        if (const auto last = children.last[*parent]) {
          children.next[*last] = index;
        } else {
          children.first[*parent] = index;
        }

        children.last[*parent] = index;
      }
    }

    return children;
  }

  template <Allocator Memory>
  void ActivityOrder<Memory>::emitForest() noexcept {
    const auto children = linkChildren();
    std::array<std::size_t, maximum_entries> positions{};
    std::optional<std::size_t> previous_source;
    std::optional<std::uint64_t> previous_project;

    output_.count = 0;
    for (std::size_t root_index = 0; root_index < count_; ++root_index) {
      const auto& root = nodes_[root_index];
      if (root.parent) {
        continue;
      }

      auto current = root_index;
      std::size_t depth = 0;

      while (true) {
        auto entry = nodes_[current];

        entry.depth = depth;
        entry.parent = entry.parent ? std::optional{positions[*entry.parent]} : std::nullopt;
        positions[current] = output_.count;
        entry.first_in_project = depth == 0 && (output_.count == 0 || previous_source != root.source || previous_project != root.project);
        output_.entries[output_.count++] = entry;
        if (const auto child = children.first[current]) {
          current = *child;
          ++depth;
          continue;
        }

        while (current != root_index && !children.next[current]) {
          current = *nodes_[current].parent;
          --depth;
        }

        if (current == root_index) {
          break;
        }

        current = *children.next[current];
      }

      previous_source = root.source;
      previous_project = root.project;
    }
  }

  std::string_view AgentStatusPresentation::word(AgentStatus status, AgentBlockedReason reason) noexcept {
    switch (status) {
    case AgentStatus::working:
      return "Working";
    case AgentStatus::blocked:
      switch (reason) {
      case AgentBlockedReason::permission:
        return "Approval";
      case AgentBlockedReason::question:
        return "Question";
      case AgentBlockedReason::plan:
        return "Review plan";
      default:
        return "Needs input";
      }
    case AgentStatus::done:
      return "Done";
    case AgentStatus::failed:
      return "Failed";
    case AgentStatus::ready:
      return {};
    case AgentStatus::unknown:
      return "Unknown";
    }

    return {};
  }

  PaletteRole AgentStatusPresentation::color(AgentStatus status) noexcept {
    switch (status) {
    case AgentStatus::working:
      return PaletteRole::teal;
    case AgentStatus::done:
      return PaletteRole::green;
    case AgentStatus::blocked:
      return PaletteRole::yellow;
    case AgentStatus::failed:
      return PaletteRole::red;
    default:
      return PaletteRole::overlay1;
    }
  }

  auto AgentStatusPresentation::age(std::uint32_t seconds, bool duration) -> Age {
    Age result;

    if (seconds < seconds_per_minute) {
      if (duration) {
        result.appendDecimal(seconds);
        result.append("s");
      } else {
        result.append("now");
      }
    } else if (seconds < seconds_per_hour) {
      result.appendDecimal(seconds / seconds_per_minute);
      result.append("m");
    } else if (seconds < seconds_per_day) {
      result.appendDecimal(seconds / seconds_per_hour);
      result.append("h");
    } else {
      result.appendDecimal(std::min(seconds / seconds_per_day, maximum_days));
      result.append("d");
    }

    return result;
  }

  auto AgentStatusPresentation::text(AgentStatus status, AgentBlockedReason reason, std::uint32_t seconds, bool connected) -> Text {
    Text result;

    if (status == AgentStatus::ready && connected) {
      result.append(age(seconds).view());
    } else {
      result.append(connected ? word(status, reason) : "offline");
      // How long an agent has worked or waited is what decides which one to visit first.
      if (connected && status != AgentStatus::unknown) {
        result.append(" ");
        result.append(age(seconds, true).view());
      }
    }

    return result;
  }

  float AgentStatusPresentation::pulse(std::uint8_t frame) noexcept {
    constexpr unsigned frame_count = 17;
    constexpr unsigned step_count = 6;
    constexpr float middle_step = 3;
    constexpr float minimum_alpha = 0.65F;
    constexpr float alpha_range = 0.35F;
    const auto quantized_step = (static_cast<unsigned>(frame) % frame_count) * step_count / frame_count;
    const auto step = static_cast<float>(quantized_step);
    const auto scaled_alpha = alpha_range * std::abs(step - middle_step) / middle_step;

    return minimum_alpha + scaled_alpha;
  }

  ProgressGeometry ProgressGeometry::derive(Rect area, float ratio, PaneProgressState state, bool compact) noexcept {
    ProgressGeometry geometry;
    const auto capsule_height = std::min(area.height, height * ratio);
    const auto capsule_width = compact ? std::min(area.width, compactWidth(ratio)) : area.width;

    geometry.background = {.x = area.x + area.width - capsule_width, .y = area.y + ((area.height - capsule_height) / 2), .width = capsule_width, .height = capsule_height};
    const auto side = std::max(0.0F, std::min({ring_side * ratio, capsule_height - (ring_inset * ratio), capsule_width - (2 * padding * ratio)}));

    geometry.ring = {.x = geometry.background.x + (padding * ratio), .y = geometry.background.y + ((capsule_height - side) / 2), .width = side, .height = side};
    if (side <= 0) {
      return geometry;
    }

    const auto stroke = std::max(1.0F, side * mark_stroke_ratio);
    const auto center = geometry.ring.x + (side / 2);
    const auto top = geometry.ring.y + (side * mark_top_ratio);

    geometry.mark_radius = stroke / 2;
    if (state == PaneProgressState::pause) {
      for (const auto offset : pause_offsets) {
        geometry.marks[geometry.mark_count++] = {.x = center + (offset * stroke), .y = top, .width = stroke, .height = side * pause_height_ratio};
      }
    } else if (state == PaneProgressState::error) {
      geometry.marks[geometry.mark_count++] = {.x = center - (stroke / 2), .y = top, .width = stroke, .height = side * error_height_ratio};
      geometry.marks[geometry.mark_count++] = {.x = center - (stroke / 2), .y = geometry.ring.y + (side * error_dot_ratio), .width = stroke, .height = stroke};
    }

    return geometry;
  }

  auto PaneStatusChip::text(AgentStatus status, AgentBlockedReason reason, std::uint32_t seconds) -> Text {
    Text result;

    switch (status) {
    case AgentStatus::blocked:
      switch (reason) {
      case AgentBlockedReason::permission:
        result.append("permission");
        break;
      case AgentBlockedReason::question:
        result.append("question");
        break;
      case AgentBlockedReason::plan:
        result.append("plan");
        break;
      default:
        result.append("blocked");
        break;
      }

      break;
    case AgentStatus::working:
      result.append("working ");
      if (seconds < AgentStatusPresentation::seconds_per_minute) {
        result.appendDecimal(seconds);
        result.append("s");
      } else if (seconds < AgentStatusPresentation::seconds_per_hour) {
        result.appendDecimal(seconds / AgentStatusPresentation::seconds_per_minute);
        result.append("m");
      } else {
        result.appendDecimal(seconds / AgentStatusPresentation::seconds_per_hour);
        result.append("h");
      }

      break;
    case AgentStatus::done:
      result.append("done");
      break;
    case AgentStatus::failed:
      result.append("failed");
      break;
    case AgentStatus::ready:
      result.append("ready");
      break;
    case AgentStatus::unknown:
      break;
    }

    return result;
  }

  PaletteRole PaneStatusChip::color(AgentStatus status) noexcept {
    return status == AgentStatus::ready ? PaletteRole::green : AgentStatusPresentation::color(status);
  }

  auto PaneProgressPresentation::text(PaneProgressState state, std::uint8_t percent) -> Text {
    Text result;

    switch (state) {
    case PaneProgressState::indeterminate:
      result.append("Working");
      break;
    case PaneProgressState::pause:
      result.append("Paused");
      break;
    case PaneProgressState::error:
      result.append("Error");
      break;
    case PaneProgressState::set:
      result.appendDecimal(percent);
      result.append("%");
      break;
    case PaneProgressState::remove:
      break;
    }

    return result;
  }

  PaletteRole PaneProgressPresentation::color(PaneProgressState state) noexcept {
    switch (state) {
    case PaneProgressState::error:
      return PaletteRole::red;
    case PaneProgressState::pause:
      return PaletteRole::yellow;
    default:
      return PaletteRole::teal;
    }
  }

  PaneHeaderGeometry PaneHeaderGeometry::derive(Rect row, const PaneHeaderMetrics& metrics, const PaneHeaderMeasurements& measurements) noexcept {
    PaneHeaderGeometry result;
    const auto ratio = metrics.ratio;
    const auto band_height = std::min(row.height, metrics.maximum_band_height);
    if (band_height <= 0 || row.width <= 0) {
      return result;
    }

    Rect band{.x = row.x + (margin * ratio), .y = row.y, .width = std::max(0.0F, row.width - (2 * margin * ratio)), .height = band_height};
    const auto reserved = measurements.index + measurements.chip + (minimum_text_room * ratio);
    auto progress_width = measurements.progress;
    if (progress_width > std::min(band.width / 2, std::max(0.0F, band.width - reserved))) {
      result.compact_progress = true;
      progress_width = measurements.compact_progress;
    }

    const auto attention_width = measurements.needs_attention ? measurements.chip : 0;
    if (progress_width > 0 && progress_width + measurements.index + attention_width + (minimum_text_room * ratio) <= band.width) {
      result.progress = {.x = band.x + band.width - progress_width, .y = band.y, .width = progress_width, .height = band.height};
      band.width = std::max(0.0F, band.width - progress_width - (part_gap * ratio));
    }

    const auto end = band.x + band.width;
    const auto index_room = measurements.needs_attention ? std::max(0.0F, band.width - measurements.chip - part_gap * ratio) : band.width;
    const auto index_width = std::min(measurements.index, index_room);

    result.index = {.x = band.x, .y = band.y, .width = index_width, .height = band.height};
    auto x = band.x + index_width + (index_width > 0 ? part_gap * ratio : 0);
    const auto chip_width = measurements.chip <= end - x ? measurements.chip : 0;
    const auto text_end = end - (chip_width != 0 ? chip_width + (chip_gap * ratio) : 0);
    const auto paused_width = measurements.paused > 0 ? measurements.paused + (chip_gap * ratio) : 0;
    const bool paused_fits = paused_width != 0 && paused_width <= text_end - x;
    const auto name_width = std::max(0.0F, text_end - x - (paused_fits ? paused_width : 0));

    result.name = {.x = x, .y = band.y, .width = name_width, .height = band.height};
    x += std::min(name_width, measurements.name);
    if (paused_fits) {
      x += chip_gap * ratio;
      result.paused = {.x = x, .y = band.y, .width = std::max(0.0F, text_end - x), .height = band.height};
    }

    if (chip_width != 0) {
      result.chip = {.x = end - chip_width, .y = band.y, .width = chip_width, .height = band.height};
    }

    return result;
  }

  template <Allocator Memory>
  tbc::view<ProjectActivity, tbc::lt::a> ProjectActivity::derive(tbc::view<const WorkspaceReplica<Memory>&, tbc::lt::a> workspaces, std::span<const Agent<Memory>> agents, std::uint64_t project) noexcept {
    ProjectActivity result;

    result.worktrees = static_cast<std::size_t>(std::ranges::count(workspaces.worktrees(), project, &Worktree<Memory>::source));
    const auto index = workspaces.indexOf(project);
    if (index < workspaces.entries().size()) {
      result.path = workspaces.entries()[index].path;
    }

    for (std::size_t index = 0; index < agents.size(); ++index) {
      const auto& agent = agents[index];
      if (agent.location.workspace.kind != WorkspaceLocation::Kind::workspace || workspaces.projectOf(agent.location.workspace.id) != project) {
        continue;
      }

      if (workspaces.worktreeOfWorkspace(agent.location.workspace.id) != nullptr || workspaces.worktree(agent.work_tree) != nullptr) {
        result.working += static_cast<std::size_t>(agent.status == AgentStatus::working);
        result.finished += static_cast<std::size_t>(agent.status == AgentStatus::done || agent.status == AgentStatus::ready);
      }

      if (AgentOrder::attention(agent.status) == AgentOrder::Attention::needs_input) {
        ++result.waiting;
        if (!result.urgent || AgentOrder::priority(agent) < AgentOrder::priority(agents[*result.urgent])) {
          result.urgent = index;
        }
      }
    }

    return result;
  }

  tbc::view<std::optional<std::string_view>, tbc::lt::a> ProjectActivity::summary(tbc::view<Text&, tbc::lt::a> storage) const {
    storage.truncate(0);
    if (worktrees == 0 || !path) {
      return std::nullopt;
    }

    storage.append("\u2387 ");
    storage.appendDecimal(worktrees);
    storage.append(" \u00b7 \u25cc ");
    storage.appendDecimal(working);
    storage.append(" \u2713 ");
    storage.appendDecimal(finished);
    storage.append("  ");
    if (path->size() > label_text_capacity - storage.view().size()) {
      return std::nullopt;
    }

    storage.append(*path);

    return storage.view();
  }

  auto ProjectActivity::attentionLabel() const -> Attention {
    Attention label;

    if (waiting != 0) {
      label.append("! ");
      label.appendDecimal(waiting);
    }

    return label;
  }

  float TabActivity::width() const noexcept {
    switch (kind) {
    case Kind::dot:
      return dot_side;
    case Kind::spinner:
      return spinner_side;
    case Kind::progress:
      return ProgressGeometry::compactWidth();
    default:
      return 0;
    }
  }

  template <Allocator Memory>
  TabActivity TabActivity::derive(const Tab<Memory>& tab, PaneProgressState focused, std::span<const Agent<Memory>> agents, bool selected) noexcept {
    const Agent<Memory>* urgent = nullptr;

    for (const auto& agent : agents) {
      if (sameTab(agent.location, tab.location) && (urgent == nullptr || AgentOrder::priority(agent) < AgentOrder::priority(*urgent))) {
        urgent = &agent;
      }
    }

    TabActivity activity;

    if (urgent != nullptr && AgentOrder::attention(urgent->status) == AgentOrder::Attention::needs_input) {
      activity.attention = AgentStatusPresentation::color(urgent->status);
    }

    if (selected && tab.layout.nodes().size() == 1 && focused != PaneProgressState::remove) {
      activity.kind = Kind::progress;
      if (focused == PaneProgressState::error) {
        activity.color = PaletteRole::red;
      } else if (focused == PaneProgressState::pause) {
        activity.color = PaletteRole::yellow;
      }

      return activity;
    }

    if (urgent == nullptr) {
      return activity;
    }

    switch (urgent->status) {
    case AgentStatus::working:
      activity.kind = Kind::spinner;
      break;
    case AgentStatus::blocked:
    case AgentStatus::failed:
    case AgentStatus::done:
      activity.kind = Kind::dot;
      activity.color = AgentStatusPresentation::color(urgent->status);
      break;
    default:
      break;
    }

    return activity;
  }

  template <Allocator Memory>
  auto TaskCardLabels::facts(const Worktree<Memory>& task) -> Facts {
    Facts parts;

    if (task.diff_files != 0) {
      append(parts.added, "+");
      decimal(parts.added, task.diff_added);
      append(parts.removed, "\u2212");
      decimal(parts.removed, task.diff_removed);
      append(parts.files, "· ");
      decimal(parts.files, task.diff_files);
    }

    if (task.commits_ahead != 0) {
      append(parts.ahead, "\u2191");
      decimal(parts.ahead, task.commits_ahead);
    }

    if (task.command_state == CommandState::exited) {
      append(parts.command, task.command_exit == 0 ? "\u2713 " : "\u2715 ");
      append(parts.command, task.command_label);
    }

    return parts;
  }

  template <Allocator Memory>
  auto TaskCardLabels::activity(const Agent<Memory>& agent) noexcept -> Activity {
    switch (agent.status) {
    case AgentStatus::blocked:
      return {.text = agent.detail, .color = PaletteRole::yellow};
    case AgentStatus::failed:
      return {.text = agent.detail, .color = PaletteRole::red};
    case AgentStatus::done:
    case AgentStatus::ready: {
      const auto final = agent.finalLine();

      return {.text = final.empty() ? std::string_view{agent.detail} : final, .color = PaletteRole::subtext0};
    }
    default:
      return agent.plan_total == 0 ? Activity{.text = agent.detail} : Activity{.text = agent.plan_step, .color = PaletteRole::subtext0, .plan = true};
    }
  }

  float TaskCardLabels::contextShare(AgentStatus state, bool signal) noexcept {
    if (!signal) {
      return 1;
    }

    switch (state) {
    case AgentStatus::blocked:
    case AgentStatus::failed:
      return waiting_context_share;
    case AgentStatus::done:
    case AgentStatus::ready:
      return resting_context_share;
    default:
      return context_share;
    }
  }

  template <Allocator Memory>
  tbc::view<std::string_view, tbc::lt::static_storage> TaskCardLabels::commandState(const Worktree<Memory>& task, bool connected) noexcept {
    if (!connected) {
      return "offline · last known";
    }

    switch (task.command_state) {
    case CommandState::running:
      return "running";
    case CommandState::exited:
      return task.command_exit == 0 ? "exited successfully" : "failed";
    default:
      return {};
    }
  }

  template <Allocator Memory>
  tbc::view<std::string_view, tbc::lt::a> TaskCardLabels::commandFacts(std::string_view machine, const Worktree<Memory>& task, bool connected, tbc::view<Text&, tbc::lt::a> storage) {
    const auto status = commandState(task, connected);

    storage.truncate(0);
    try {
      if (!machine.empty()) {
        storage.append(machine);
        storage.append(" · ");
      }

      storage.append(task.handle());
      storage.append(" · ");
      storage.append(status);

      return storage.view();
    } catch (const std::length_error&) {
      return status;
    }
  }

  void TaskCardLabels::append(Text& storage, std::string_view text) {
    storage.append(text.substr(0, text_capacity - storage.view().size()));
  }

  void TaskCardLabels::decimal(Text& storage, std::uint32_t value) {
    constexpr auto decimal_digits = std::numeric_limits<std::uint32_t>::digits10 + 1;
    std::array<char, decimal_digits> digits{};
    const auto result = std::to_chars(digits.data(), digits.data() + digits.size(), value);

    append(storage, {digits.data(), static_cast<std::size_t>(result.ptr - digits.data())});
  }

  template tbc::view<const Worktree<Memory>*, tbc::lt::a> AgentOrder::taskRow<Memory>(tbc::view<const WorkspaceReplica<Memory>&, tbc::lt::a> workspaces, const Agent<Memory>& agent) noexcept;
  template tbc::view<const Worktree<ConcurrentMemory>*, tbc::lt::a> AgentOrder::taskRow<ConcurrentMemory>(tbc::view<const WorkspaceReplica<ConcurrentMemory>&, tbc::lt::a> workspaces, const Agent<ConcurrentMemory>& agent) noexcept;
  template AgentOrder::Priority AgentOrder::priority<Memory>(const Agent<Memory>& agent) noexcept;
  template AgentOrder::Priority AgentOrder::priority<ConcurrentMemory>(const Agent<ConcurrentMemory>& agent) noexcept;
  template AgentOrder::Plan AgentOrder::arrange<Memory>(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory>& workspaces) noexcept;
  template AgentOrder::Plan AgentOrder::arrange<ConcurrentMemory>(std::span<const Agent<ConcurrentMemory>> agents, const WorkspaceReplica<ConcurrentMemory>& workspaces) noexcept;
  template class ActivityOrder<Memory>;
  template class ActivityOrder<ConcurrentMemory>;
  template tbc::view<ProjectActivity, tbc::lt::a> ProjectActivity::derive<Memory>(tbc::view<const WorkspaceReplica<Memory>&, tbc::lt::a> workspaces, std::span<const Agent<Memory>> agents, std::uint64_t project) noexcept;
  template tbc::view<ProjectActivity, tbc::lt::a> ProjectActivity::derive<ConcurrentMemory>(tbc::view<const WorkspaceReplica<ConcurrentMemory>&, tbc::lt::a> workspaces, std::span<const Agent<ConcurrentMemory>> agents, std::uint64_t project) noexcept;
  template TabActivity TabActivity::derive<Memory>(const Tab<Memory>& tab, PaneProgressState focused, std::span<const Agent<Memory>> agents, bool selected) noexcept;
  template TabActivity TabActivity::derive<ConcurrentMemory>(const Tab<ConcurrentMemory>& tab, PaneProgressState focused, std::span<const Agent<ConcurrentMemory>> agents, bool selected) noexcept;
  template TaskCardLabels::Facts TaskCardLabels::facts<Memory>(const Worktree<Memory>& task);
  template TaskCardLabels::Facts TaskCardLabels::facts<ConcurrentMemory>(const Worktree<ConcurrentMemory>& task);
  template TaskCardLabels::Activity TaskCardLabels::activity<Memory>(const Agent<Memory>& agent) noexcept;
  template TaskCardLabels::Activity TaskCardLabels::activity<ConcurrentMemory>(const Agent<ConcurrentMemory>& agent) noexcept;
  template tbc::view<std::string_view, tbc::lt::static_storage> TaskCardLabels::commandState<Memory>(const Worktree<Memory>& task, bool connected) noexcept;
  template tbc::view<std::string_view, tbc::lt::static_storage> TaskCardLabels::commandState<ConcurrentMemory>(const Worktree<ConcurrentMemory>& task, bool connected) noexcept;
  template tbc::view<std::string_view, tbc::lt::a> TaskCardLabels::commandFacts<Memory>(std::string_view machine, const Worktree<Memory>& task, bool connected, tbc::view<TaskCardLabels::Text&, tbc::lt::a> storage);
  template tbc::view<std::string_view, tbc::lt::a> TaskCardLabels::commandFacts<ConcurrentMemory>(std::string_view machine, const Worktree<ConcurrentMemory>& task, bool connected, tbc::view<TaskCardLabels::Text&, tbc::lt::a> storage);

}

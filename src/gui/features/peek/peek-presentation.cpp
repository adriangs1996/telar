module telar.gui.features.peek;

import std;

import telar.tbc;
import telar.base.memory.allocators;
import telar.gui.foundation.agents;
import telar.gui.foundation.core;
import telar.gui.foundation.forms;
import telar.gui.foundation.model;
import telar.base.ds;

namespace telar::gui::features::peek {

  template <Allocator Memory>
  tbc::view<std::string_view, tbc::lt::a> PeekLabels::title(tbc::view<const Agent<Memory>&, tbc::lt::a> agent, tbc::view<const Worktree<Memory>*, tbc::lt::a> task) noexcept {
    if (task == nullptr) {
      return AgentCardLabels::title({}, agent.display_name);
    }

    return task->title.empty() ? std::string_view{task->branch} : std::string_view{task->title};
  }

  template <Allocator Memory>
  PeekLabels::Facts PeekLabels::facts(const Agent<Memory>& agent, const Worktree<Memory>* task) {
    Facts result;

    append(result, AgentCardLabels::title({}, agent.display_name));
    append(result, " · ");
    constexpr ds::Array statuses{std::string_view{"unknown"}, std::string_view{"working"}, std::string_view{"blocked"}, std::string_view{"ready"}, std::string_view{"failed"}, std::string_view{"done"}};
    const auto status = static_cast<std::size_t>(agent.status);

    append(result, statuses[status < statuses.size() ? status : 0]);
    if (task != nullptr) {
      append(result, "  ⎇ ");
      append(result, task->handle());
    }

    if (agent.plan_total != 0) {
      append(result, "  ");
      decimal(result, agent.plan_done);
      append(result, "/");
      decimal(result, agent.plan_total);
      append(result, " ");
      append(result, agent.plan_step);
    } else if (!agent.detail.empty()) {
      append(result, "  ");
      append(result, agent.detail);
    }

    return result;
  }

  void PeekLabels::append(Facts& storage, std::string_view text) {
    storage.append(text.substr(0, facts_bytes - storage.view().size()));
  }

  void PeekLabels::decimal(Facts& storage, std::uint16_t value) {
    constexpr auto capacity = std::numeric_limits<std::uint16_t>::digits10 + 1;
    ds::Array<char, capacity> digits{};
    const auto result = std::to_chars(digits.dataMut(), digits.dataMut() + digits.size(), value);

    append(storage, {digits.data(), static_cast<std::size_t>(result.ptr - digits.data())});
  }

  template tbc::view<std::string_view, tbc::lt::a> PeekLabels::title<Memory>(tbc::view<const Agent<Memory>&, tbc::lt::a> agent, tbc::view<const Worktree<Memory>*, tbc::lt::a> task) noexcept;
  template tbc::view<std::string_view, tbc::lt::a> PeekLabels::title<ConcurrentMemory>(tbc::view<const Agent<ConcurrentMemory>&, tbc::lt::a> agent, tbc::view<const Worktree<ConcurrentMemory>*, tbc::lt::a> task) noexcept;
  template PeekLabels::Facts PeekLabels::facts<Memory>(const Agent<Memory>& agent, const Worktree<Memory>* task);
  template PeekLabels::Facts PeekLabels::facts<ConcurrentMemory>(const Agent<ConcurrentMemory>& agent, const Worktree<ConcurrentMemory>* task);

  std::string_view lastLines(std::string_view text, std::uint16_t count) noexcept {
    const auto last = text.find_last_not_of(" \n\r\t");
    if (last == std::string_view::npos) {
      return {};
    }

    text.remove_suffix(text.size() - last - 1);
    auto start = text.size();
    std::uint16_t seen = 0;

    while (start > 0 && seen < count) {
      --start;
      if (text[start] == '\n') {
        ++seen;
        if (seen == count) {
          ++start;
          break;
        }
      }
    }

    text.remove_prefix(start);

    return text;
  }

  PeekGeometry PeekGeometry::measure(CellRectangle host) noexcept {
    const auto modal = NamePromptGeometry::measure(host, requested_size);
    PeekGeometry result;

    result.bounds = modal.bounds;
    result.title = modal.title;
    const auto content = result.bounds.width > 2 && result.bounds.height > 2 ? result.bounds.inner(1) : result.bounds;
    if (content.height < chrome_rows) {
      return result;
    }

    result.facts = content.row(0);
    result.screen = content.row(1);
    result.screen.height = content.height - chrome_rows;
    result.field = content.row(content.height - field_rows_from_end);
    result.footer = content.row(content.height - 1);

    return result;
  }

}

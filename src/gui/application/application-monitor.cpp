module telar.gui.application;

import std;

import telar.base.ds;
import telar.base.text.utf8;
import telar.gui.features.monitor;
import telar.wire.monitor;

namespace telar::gui::application::monitor {
  namespace {

    CellText named(std::string_view text) {
      CellText result;

      result.assign(runtime::utf8Prefix(text, features::monitor::cell_text_bytes));
      return result;
    }

    // The tab's label, else what runs in its foreground, else its place among the tabs.
    CellText tabName(const Tab<Memory>& tab) {
      if (!tab.label.view().empty()) {
        return named(tab.label.view());
      }

      if (!tab.foreground.view().empty()) {
        return named(tab.foreground.view());
      }

      constexpr std::string_view prefix = "tab ";
      ds::Array<char, prefix.size() + std::numeric_limits<std::uint32_t>::digits10 + 1> text{};
      auto* const start = std::ranges::copy(prefix, text.dataMut()).out;
      const auto converted = std::to_chars(start, std::to_address(text.viewMut().end()), tab.position + 1U);

      return named(std::string_view{text.view().first(static_cast<std::size_t>(converted.ptr - text.data()))});
    }

    // The title of the agent the pane runs, else its name or its provider's; empty when it runs none.
    CellText agentName(const Session& session, std::uint64_t pane_id) {
      for (const auto& agent : session.agent_list.entries()) {
        if (agent.pane_id != pane_id) {
          continue;
        }

        for (const auto text : {agent.title.view(), agent.display_name.view(), agent.provider_name.view()}) {
          if (!text.empty()) {
            return named(text);
          }
        }
      }

      return {};
    }

  }

  CellText ownerName(const Session& session, std::uint64_t pane_id, ProcessOwner owner) {
    if (pane_id == 0) {
      return {};
    }

    if (owner == ProcessOwner::agent || owner == ProcessOwner::agent_child) {
      if (auto name = agentName(session, pane_id); !name.view().empty()) {
        return name;
      }
    }

    for (const auto& tab : session.tabs) {
      const auto members = tab->members.view();

      if (std::ranges::contains(members, pane_id, &TabMember::pane_id)) {
        return tabName(*tab);
      }
    }

    return {};
  }

  bool available(const Session& session) noexcept {
    return session.ready() && session.monitors();
  }

  bool refresh(Session& session) {
    if (!available(session) || session.monitor.waiting != 0) {
      return false;
    }

    const auto asked = session.link.ask(features::monitor::query(session.monitor));
    if (!asked) {
      return false;
    }

    features::monitor::wait(session.monitor, *asked);
    return true;
  }

  const State& state(const Session& session) noexcept {
    return session.monitor;
  }

  View& view(Session& session) noexcept {
    return session.monitor.view;
  }

  bool signal(Session& session, const ProcessInstance& process, ProcessSignal signal) {
    if (!available(session) || session.monitor.acting != 0) {
      return false;
    }

    const auto asked = session.link.ask(RequestProcessSignal{.process = process, .signal = signal});
    if (!asked) {
      return false;
    }

    session.monitor.acting = *asked;
    return true;
  }

  bool prioritize(Session& session, const ProcessInstance& process, std::int32_t nice) {
    if (!available(session) || session.monitor.acting != 0) {
      return false;
    }

    const auto asked = session.link.ask(RequestProcessPriority{.process = process, .nice = nice});
    if (!asked) {
      return false;
    }

    session.monitor.acting = *asked;
    return true;
  }

}

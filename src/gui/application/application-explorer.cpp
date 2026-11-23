module telar.gui.application;

import std;

import telar.base.ds;
import telar.tbc;
import telar.config.client;
import telar.gui.features.explorer;
import telar.gui.features.nvim;
import telar.wire.files;

namespace telar::gui::application::explorer {

  namespace feature = features::explorer;

  namespace {

    using feature::Action;
    using feature::ActionKind;
    using feature::Context;
    using feature::PaneFact;
    using feature::PaneKind;

    // The panes of a tab the explorer reads: as many as a tab holds.
    constexpr std::size_t tab_panes = 64;

    constexpr bool isShell(std::string_view program) noexcept {
      constexpr ds::Array<std::string_view, 9> shells{"zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "nu", "pwsh"};

      return std::ranges::contains(shells, program);
    }

    // What the explorer reads of the session: the panes of the tab that shows, the one focused,
    // and the directory of the workspace. It views the session's panes, agents and workspaces.
    struct Facts {
      ds::Array<PaneFact, tab_panes> panes{};
      std::size_t count = 0;
      std::uint64_t focused = 0;
      std::string_view workspace;
    };

    // Reads the facts from the fields of the session that hold them, each lent on its own so a
    // use case can change the explorer's state while it reads them.
    void gather(
        tbc::mut_a<Facts> facts,
        tbc::ref_a<Panes> panes,
        tbc::ref_a<Tabs> tabs,
        ds::Option<TabLocation> active,
        tbc::ref_a<ds::Vec<Agent<Memory>, Memory>> agents,
        const features::nvim::State& editors,
        tbc::ref_a<ds::Vec<Workspace<Memory>, Memory>> workspaces
    ) {
      const auto* tab = activeTab(tabs, active);
      if (tab == nullptr) {
        return;
      }

      facts.focused = tab->focused_pane;
      for (const auto& member : tab->members) {
        const auto* pane = findPane(panes, member.pane_id);
        if (pane == nullptr || pane->exited || facts.count == facts.panes.size()) {
          continue;
        }

        auto& fact = facts.panes.atMut(facts.count);

        fact = {.id = pane->id, .number = static_cast<std::uint16_t>(facts.count + 1), .title = pane->foreground.view(), .cwd = pane->cwd.view()};
        if (features::nvim::find(editors, pane->id) != nullptr) {
          fact.kind = PaneKind::editor;
          fact.title = "nvim";
        } else if (const auto agent = std::ranges::find(agents, pane->id, &Agent<Memory>::pane_id); agent != agents.end()) {
          fact.kind = PaneKind::agent;
          fact.title = !agent->display_name.view().empty() ? agent->display_name.view() : agent->provider_name.view();
        } else {
          fact.kind = isShell(fact.title) ? PaneKind::shell : PaneKind::program;
        }

        if (fact.title.empty()) {
          fact.title = "shell";
        }

        ++facts.count;
      }

      for (const auto& workspace : workspaces) {
        if (workspace.location.kind == tab->location.workspace.kind && workspace.location.id == tab->location.workspace.id) {
          facts.workspace = workspace.path.view();
        }
      }
    }

    // The context of the facts and of the machine: it views both.
    tbc::val_a<Context> contextOf(tbc::ref_a<Facts> facts, tbc::ref_a<Host> host) noexcept {
      return {.panes = facts.panes.view().first(facts.count), .focused = facts.focused, .workspace = facts.workspace, .home = host.home, .machine = host.name, .local = host.local};
    }

    // Asks the runtime for what the windows of the machine lack, while it may ask for more.
    void reconcile(Session& session, const View& view, const Host& host) {
      while (session.ready() && feature::mayAsk(session.explorer)) {
        const auto need = feature::need(view, session.explorer, host.machine);
        if (!need) {
          return;
        }

        ds::Option<std::uint64_t> request;

        switch (need->kind) {
        case feature::NeedKind::listing:
          request = session.link.ask(feature::listing(session.explorer, need->path));
          break;
        case feature::NeedKind::sizes:
          request = session.link.ask(feature::measure(session.explorer, need->path));
          break;
        case feature::NeedKind::changes:
          request = session.link.ask(QueryChanges{.path = need->path});
          break;
        case feature::NeedKind::inspection:
          request = session.link.ask(InspectFile{.path = need->path});
          break;
        }

        // A full queue is no failure: the next refresh asks again.
        if (!request) {
          return;
        }

        feature::asked(session.explorer, *need, *request);
      }
    }

    // Types `text` at the pane: in telar's own line when the pane edits there.
    void hand(Session& session, std::uint64_t pane_id, std::string_view text) {
      if (prompt::edits(session, pane_id)) {
        prompt::text(session, pane_id, text);
      } else {
        session.input(pane_id, text);
      }
    }

    Effect leave(View& view) noexcept {
      // Over the panes the explorer hides what it just handed over; beside them it stays.
      if (view.pinned) {
        return Effect::none;
      }

      feature::close(view);
      return Effect::closed;
    }

    Effect perform(Session& session, View& view, const Host& host, const Action& action) {
      switch (action.kind) {
      case ActionKind::none:
      case ActionKind::pin:
        return Effect::none;
      case ActionKind::close:
        feature::close(view);
        return Effect::closed;
      case ActionKind::copy:
        return Effect::copy;
      case ActionKind::insert:
      case ActionKind::mention:
        hand(session, action.pane, view.text.view());
        if (action.kind == ActionKind::mention) {
          workbench::focusPane(session, action.pane);
        }

        return leave(view);
      case ActionKind::open: {
        const auto* tab = activeTab(session.tabs, session.active_tab);
        const auto from = action.pane != 0 ? action.pane : tab == nullptr ? 0
                                                                          : tab->focused_pane;

        for (const auto& path : view.paths) {
          static_cast<void>(nvim::edit(session, from, {.path = path.view()}));
        }

        return leave(view);
      }
      case ActionKind::change_directory: {
        ds::String<Memory> command{session.memory, "cd "};

        feature::appendTyped(command, view.text.view(), {}, host.home, true);
        session.runCommand(action.pane, command.view());
        return leave(view);
      }
      case ActionKind::split:
        static_cast<void>(workbench::splitAt(session, ClientLayoutAxis::horizontal, view.text.view()));
        return leave(view);
      case ActionKind::focus_pane:
        workbench::focusPane(session, action.pane);
        return leave(view);
      case ActionKind::apply: {
        feature::Operations operations{};
        const auto count = feature::operations(view, host.machine, operations);
        if (count == 0 || session.explorer.applying != 0) {
          return Effect::none;
        }

        if (const auto request = session.link.ask(ChangeFiles{.overwrite = action.overwrite, .operations = operations.view().first(count)})) {
          feature::applying(session.explorer, *request, false);
        }

        return Effect::none;
      }
      case ActionKind::undo:
        if (session.explorer.applying == 0) {
          if (const auto request = session.link.ask(UndoFileChanges{})) {
            feature::applying(session.explorer, *request, true);
          }
        }

        return Effect::none;
      case ActionKind::commit:
        if (session.explorer.committing == 0 && !view.windows.empty()) {
          if (const auto request = session.link.ask(CommitChanges{.path = feature::window(view).root.view(), .message = view.text.view()})) {
            feature::committing(session.explorer, *request);
          }
        }

        return Effect::none;
      }

      return Effect::none;
    }

    // What every use case ends with: the action done, and the runtime asked for what is lacking.
    Effect finish(Session& session, View& view, const Host& host, const Action& action) {
      const auto effect = perform(session, view, host, action);

      reconcile(session, view, host);
      return effect;
    }

  }

  bool available(const Session& session) noexcept {
    return session.ready() && session.explores();
  }

  bool open(Session& session, View& view, const Host& host) {
    if (!available(session)) {
      return false;
    }

    Facts facts;

    gather(facts, session.panes, session.tabs, session.active_tab, session.agent_list.entries(), session.nvim, session.workspace_list.entries());
    feature::open(view, session.explorer, contextOf(facts, host), host.machine);
    reconcile(session, view, host);
    return true;
  }

  void close(View& view) noexcept {
    feature::close(view);
  }

  Effect press(Session& session, View& view, const Host& host, KeyChord chord) {
    Facts facts;

    gather(facts, session.panes, session.tabs, session.active_tab, session.agent_list.entries(), session.nvim, session.workspace_list.entries());

    const auto action = feature::press(view, session.explorer, contextOf(facts, host), chord);

    return finish(session, view, host, action);
  }

  void typed(Session& session, View& view, const Host& host, std::string_view text) {
    Facts facts;

    gather(facts, session.panes, session.tabs, session.active_tab, session.agent_list.entries(), session.nvim, session.workspace_list.entries());
    feature::typed(view, session.explorer, contextOf(facts, host), text);
    reconcile(session, view, host);
  }

  Effect submit(Session& session, View& view, const Host& host, std::string_view text) {
    Facts facts;

    gather(facts, session.panes, session.tabs, session.active_tab, session.agent_list.entries(), session.nvim, session.workspace_list.entries());

    const auto action = feature::submit(view, session.explorer, contextOf(facts, host), text);

    return finish(session, view, host, action);
  }

  void cancel(Session& session, View& view, const Host& host) {
    Facts facts;

    gather(facts, session.panes, session.tabs, session.active_tab, session.agent_list.entries(), session.nvim, session.workspace_list.entries());
    feature::cancel(view, session.explorer, contextOf(facts, host));
    reconcile(session, view, host);
  }

  void select(Session& session, View& view, const Host& host, std::size_t window, std::size_t row, bool extend, bool toggle) {
    Facts facts;

    gather(facts, session.panes, session.tabs, session.active_tab, session.agent_list.entries(), session.nvim, session.workspace_list.entries());
    feature::select(view, session.explorer, contextOf(facts, host), window, row, extend, toggle);
    reconcile(session, view, host);
  }

  Effect activate(Session& session, View& view, const Host& host, std::size_t window, std::size_t row) {
    Facts facts;

    gather(facts, session.panes, session.tabs, session.active_tab, session.agent_list.entries(), session.nvim, session.workspace_list.entries());

    const auto action = feature::activate(view, session.explorer, contextOf(facts, host), window, row);

    return finish(session, view, host, action);
  }

  void toggle(Session& session, View& view, const Host& host, std::size_t window, std::size_t row) {
    Facts facts;

    gather(facts, session.panes, session.tabs, session.active_tab, session.agent_list.entries(), session.nvim, session.workspace_list.entries());
    feature::toggle(view, session.explorer, contextOf(facts, host), window, row);
    reconcile(session, view, host);
  }

  void resize(View& view, std::size_t window, std::uint16_t rows) noexcept {
    feature::resize(view, window, rows);
  }

  void scroll(View& view, std::size_t window, std::int64_t rows) noexcept {
    feature::scroll(view, window, rows);
  }

  bool refresh(Session& session, View& view, const Host& host) {
    if (!view.open) {
      return false;
    }

    const auto before = view.revision;
    Facts facts;

    gather(facts, session.panes, session.tabs, session.active_tab, session.agent_list.entries(), session.nvim, session.workspace_list.entries());

    const auto context = contextOf(facts, host);

    feature::settle(view, session.explorer, context, host.machine);
    if (feature::follow(view, context, host.machine) || view.built != session.explorer.revision) {
      feature::rebuild(view, session.explorer, context, host.machine);
    }

    reconcile(session, view, host);
    return view.revision != before;
  }

  RowLook look(const Session& session, const View& view, const Host& host, std::size_t window, std::size_t row) {
    Facts facts;

    gather(facts, session.panes, session.tabs, session.active_tab, session.agent_list.entries(), session.nvim, session.workspace_list.entries());
    return feature::look(view, session.explorer, contextOf(facts, host), window, row);
  }

  HeaderLook header(const Session& session, const View& view, const Host& host, std::size_t window) {
    Facts facts;

    gather(facts, session.panes, session.tabs, session.active_tab, session.agent_list.entries(), session.nvim, session.workspace_list.entries());
    return feature::header(view, session.explorer, contextOf(facts, host), window);
  }

  StatusLook status(const Session& session, const View& view, const Host& host, std::size_t window) {
    Facts facts;

    gather(facts, session.panes, session.tabs, session.active_tab, session.agent_list.entries(), session.nvim, session.workspace_list.entries());
    return feature::status(view, session.explorer, contextOf(facts, host), window);
  }

  Hints hints(const Session& session, const View& view, const Host& host) {
    Facts facts;

    gather(facts, session.panes, session.tabs, session.active_tab, session.agent_list.entries(), session.nvim, session.workspace_list.entries());
    return feature::hints(view, session.explorer, contextOf(facts, host));
  }

  ds::Array<LensLook, lens_count> lenses(const Session& session, const View& view, const Host& host) {
    Facts facts;

    gather(facts, session.panes, session.tabs, session.active_tab, session.agent_list.entries(), session.nvim, session.workspace_list.entries());
    return feature::lenses(view, session.explorer, contextOf(facts, host));
  }

  tbc::val_a<std::string_view> previewText(tbc::ref_a<Session> session, const View& view) noexcept {
    return feature::previewText(view, session.explorer);
  }

  PreviewLook preview(const Session& session, const View& view, const Host& host, std::uint64_t now_seconds) {
    Facts facts;

    gather(facts, session.panes, session.tabs, session.active_tab, session.agent_list.entries(), session.nvim, session.workspace_list.entries());
    return feature::preview(view, session.explorer, contextOf(facts, host), now_seconds);
  }

}

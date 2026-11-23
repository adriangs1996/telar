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

    // The fields of the session the facts are read from. A use case that changes the explorer's
    // state names them one by one, so each is lent on its own while that state changes.
    struct Sources {
      const Panes& panes;
      const Tabs& tabs;
      ds::Option<TabLocation> active;
      const ds::Vec<Agent<Memory>, Memory>& agents;
      const features::nvim::State& editors;
      const ds::Vec<Workspace<Memory>, Memory>& workspaces;
    };

    // The agent the pane runs, if the runtime reports one there.
    tbc::val_a<const Agent<Memory>*> agentIn(tbc::ref_a<ds::Vec<Agent<Memory>, Memory>> agents, std::uint64_t pane) noexcept {
      for (const auto& agent : agents) {
        if (agent.pane_id == pane) {
          return &agent;
        }
      }

      return nullptr;
    }

    // What the pane of `fact` runs: an editor, an agent, a shell or another program.
    void name(tbc::mut_a<PaneFact> fact, tbc::holds<const Sources&, tbc::lt::a> sources) {
      if (features::nvim::find(sources.editors, fact.id) != nullptr) {
        fact.kind = PaneKind::editor;
        fact.title = "nvim";
      } else if (const auto* agent = agentIn(sources.agents, fact.id)) {
        fact.kind = PaneKind::agent;
        fact.title = !agent->display_name.view().empty() ? agent->display_name.view() : agent->provider_name.view();
      } else {
        fact.kind = isShell(fact.title) ? PaneKind::shell : PaneKind::program;
      }

      if (fact.title.empty()) {
        fact.title = "shell";
      }
    }

    void gather(tbc::mut_a<Facts> facts, tbc::holds<const Sources&, tbc::lt::a> sources) {
      const auto* tab = activeTab(sources.tabs, sources.active);
      if (tab == nullptr) {
        return;
      }

      facts.focused = tab->focused_pane;
      // The panes the session holds of the tab, which it knows before the runtime lists them.
      for (const auto& pane : sources.panes) {
        if (!sameTab(pane->location, tab->location) || pane->exited || facts.count == facts.panes.size()) {
          continue;
        }

        auto& fact = facts.panes.atMut(facts.count);

        fact = {.id = pane->id, .number = static_cast<std::uint16_t>(facts.count + 1), .title = pane->foreground.view(), .cwd = pane->cwd.view()};
        name(fact, sources);
        ++facts.count;
      }

      for (const auto& workspace : sources.workspaces) {
        if (workspace.location.kind == tab->location.workspace.kind && workspace.location.id == tab->location.workspace.id) {
          facts.workspace = workspace.path.view();
        }
      }
    }

    // The facts of the session, which they view whole: for a use case that reads its explorer.
    tbc::val_a<Facts> factsOf(tbc::ref_a<Session> session) {
      Facts facts;

      gather(facts, {.panes = session.panes, .tabs = session.tabs, .active = session.active_tab, .agents = session.agent_list.entries(), .editors = session.nvim, .workspaces = session.workspace_list.entries()});
      return facts;
    }

    // The context of the facts and of the machine: it views both.
    tbc::val_a<Context> contextOf(tbc::ref_a<Facts> facts, tbc::ref_a<Host> host) noexcept {
      return {.panes = facts.panes.view().first(facts.count), .focused = facts.focused, .workspace = facts.workspace, .home = host.home, .machine = host.name, .local = host.local};
    }

    // Runs `use`, a use case that changes the explorer's state, with that state and the context
    // around it.
    template <typename Use>
    Action act(Session& session, const Host& host, const Use& use) {
      Facts facts;

      gather(facts, {.panes = session.panes, .tabs = session.tabs, .active = session.active_tab, .agents = session.agent_list.entries(), .editors = session.nvim, .workspaces = session.workspace_list.entries()});
      return use(session.explorer, contextOf(facts, host));
    }

    // Asks the runtime for what the windows of the machine lack, while it may ask for more.
    void reconcile(Session& session, const View& view, const Host& host) {
      session.explorer.finds = session.speaks(ClientTag::find_paths);
      while (session.ready()) {
        const auto need = feature::need(view, session.explorer, host.machine);
        // A search follows what is typed, and waits for no answer on files to be asked.
        if (!need || (need->kind != feature::NeedKind::search && !feature::mayAsk(session.explorer))) {
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
        case feature::NeedKind::search:
          request = session.link.ask(feature::search(session.explorer, *need));
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
      // The explorer leaves the panes in view once it handed something over, unless it was
      // asked to stay.
      if (view.pinned) {
        return Effect::none;
      }

      feature::close(view);
      return Effect::closed;
    }

    // Opens the paths the view gathered in the editor of the tab, from `pane` or, with none
    // named, from the focused one.
    void edit(Session& session, const View& view, std::uint64_t pane) {
      if (pane == 0) {
        const auto* tab = activeTab(session.tabs, session.active_tab);

        pane = tab == nullptr ? 0 : tab->focused_pane;
      }

      for (const auto& path : view.paths) {
        static_cast<void>(nvim::edit(session, pane, {.path = path.view()}));
      }
    }

    Effect perform(Session& session, View& view, const Host& host, const Action& action) {
      switch (action.kind) {
      case ActionKind::none:
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
      case ActionKind::open:
        edit(session, view, action.pane);
        return leave(view);
      case ActionKind::change_directory: {
        ds::String<Memory> command{session.memory, "cd "};

        feature::appendTyped(command, view.text.view(), {.cwd = {}, .home = host.home});
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

    const auto facts = factsOf(session);

    session.explorer.finds = session.speaks(ClientTag::find_paths);
    feature::open(view, session.explorer, contextOf(facts, host), host.machine);
    reconcile(session, view, host);
    return true;
  }

  void close(View& view) noexcept {
    feature::close(view);
  }

  Effect press(Session& session, View& view, const Host& host, KeyChord chord) {
    const auto action = act(session, host, [&](feature::State& state, const Context& context) {
      return feature::press(view, state, context, chord);
    });

    return finish(session, view, host, action);
  }

  void typed(Session& session, View& view, const Host& host, std::string_view text) {
    const auto facts = factsOf(session);

    feature::typed(view, session.explorer, contextOf(facts, host), text);
    reconcile(session, view, host);
  }

  Effect submit(Session& session, View& view, const Host& host, std::string_view text) {
    const auto action = act(session, host, [&](feature::State& state, const Context& context) {
      return feature::submit(view, state, context, text);
    });

    return finish(session, view, host, action);
  }

  void complete(Session& session, View& view, const Host& host, std::string_view line) {
    const auto facts = factsOf(session);

    feature::complete(view, session.explorer, contextOf(facts, host), line);
    reconcile(session, view, host);
  }

  void cancel(Session& session, View& view, const Host& host) {
    const auto facts = factsOf(session);

    feature::cancel(view, session.explorer, contextOf(facts, host));
    reconcile(session, view, host);
  }

  void select(Session& session, View& view, const Host& host, const Pick& pick) {
    const auto facts = factsOf(session);

    feature::select(view, session.explorer, contextOf(facts, host), pick);
    reconcile(session, view, host);
  }

  Effect activate(Session& session, View& view, const Host& host, const Pick& pick) {
    const auto action = act(session, host, [&](feature::State& state, const Context& context) {
      return feature::activate(view, state, context, pick);
    });

    return finish(session, view, host, action);
  }

  void toggle(Session& session, View& view, const Host& host, const Pick& pick) {
    const auto facts = factsOf(session);

    feature::toggle(view, session.explorer, contextOf(facts, host), pick);
    reconcile(session, view, host);
  }

  void openMenu(Session& session, View& view, const Host& host, const Pick& pick) {
    const auto facts = factsOf(session);

    feature::openMenu(view, session.explorer, contextOf(facts, host), pick);
    reconcile(session, view, host);
  }

  Effect chooseMenu(Session& session, View& view, const Host& host, std::size_t line) {
    const auto action = act(session, host, [&](feature::State& state, const Context& context) {
      return feature::chooseMenu(view, state, context, line);
    });

    return finish(session, view, host, action);
  }

  std::size_t grab(Session& session, View& view, const Host& host, const Pick& pick) {
    const auto facts = factsOf(session);
    const auto carried = feature::grab(view, session.explorer, contextOf(facts, host), pick);

    reconcile(session, view, host);
    return carried;
  }

  Aim aim(const Session& session, const View& view, const Host& host, const Drop& drop) {
    const auto facts = factsOf(session);

    return feature::aim(view, session.explorer, contextOf(facts, host), drop);
  }

  void drop(Session& session, View& view, const Host& host, const Drop& drop) {
    const auto facts = factsOf(session);

    feature::drop(view, session.explorer, contextOf(facts, host), drop);
    reconcile(session, view, host);
  }

  void release(View& view) noexcept {
    feature::release(view);
  }

  void resize(View& view, const WindowRows& shown) noexcept {
    feature::resize(view, shown);
  }

  void scroll(View& view, const WindowRows& moved) noexcept {
    feature::scroll(view, moved);
  }

  bool refresh(Session& session, View& view, const Host& host) {
    if (!view.open) {
      return false;
    }

    const auto before = view.revision;
    const auto facts = factsOf(session);
    const auto context = contextOf(facts, host);

    feature::settle(view, session.explorer, context, host.machine);
    if (feature::follow(view, context, host.machine)) {
      feature::rebuild(view, session.explorer, context, host.machine);
    } else {
      feature::absorb(view, session.explorer, context, host.machine);
    }

    reconcile(session, view, host);
    return view.revision != before;
  }

  RowLook look(const Session& session, const View& view, const Host& host, const Pick& pick) {
    const auto facts = factsOf(session);

    return feature::look(view, session.explorer, contextOf(facts, host), pick);
  }

  HeaderLook header(const Session& session, const View& view, const Host& host, std::size_t window) {
    const auto facts = factsOf(session);

    return feature::header(view, session.explorer, contextOf(facts, host), window);
  }

  StatusLook status(const Session& session, const View& view, const Host& host, std::size_t window) {
    const auto facts = factsOf(session);

    return feature::status(view, session.explorer, contextOf(facts, host), window);
  }

  Hints hints(const Session& session, const View& view, const Host& host) {
    const auto facts = factsOf(session);

    return feature::hints(view, session.explorer, contextOf(facts, host));
  }

  ds::Array<LensLook, lens_count> lenses(const Session& session, const View& view, const Host& host) {
    const auto facts = factsOf(session);

    return feature::lenses(view, session.explorer, contextOf(facts, host));
  }

  tbc::val_a<std::string_view> previewText(tbc::ref_a<Session> session, const View& view) noexcept {
    return feature::previewText(view, session.explorer);
  }

  PreviewLook preview(const Session& session, const View& view, const Host& host, std::uint64_t now_seconds) {
    const auto facts = factsOf(session);

    return feature::preview(view, session.explorer, contextOf(facts, host), now_seconds);
  }

  MenuLook menu(const Session& session, const View& view, const Host& host) {
    const auto facts = factsOf(session);

    return feature::menu(view, session.explorer, contextOf(facts, host));
  }

}

module telar.gui.application;

import std;

import telar.base.ds;
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

    // The agent the pane runs, if the runtime reports one there.
    const Agent<Memory>* agentOf(const Session& session, std::uint64_t pane_id) noexcept {
      for (const auto& agent : session.agent_list.entries()) {
        if (agent.pane_id == pane_id) {
          return &agent;
        }
      }

      return nullptr;
    }

    // Hands `use` what the explorer reads of the session: the panes of the tab that shows, the
    // one focused, the directory of the workspace and the machine. The context views the session,
    // so it lives for the call.
    template <typename Use>
    auto with(const Session& session, const Host& host, Use&& use) {
      ds::Array<PaneFact, tab_panes> panes{};
      std::size_t count = 0;
      Context context{.home = host.home, .machine = host.name, .local = host.local};

      if (const auto* tab = activeTab(session.tabs, session.active_tab)) {
        context.focused = tab->focused_pane;
        for (const auto& member : tab->members) {
          const auto* pane = findPane(session.panes, member.pane_id);
          if (pane == nullptr || pane->exited || count == panes.size()) {
            continue;
          }

          const auto* agent = agentOf(session, pane->id);
          auto& fact = panes.atMut(count);

          fact = {.id = pane->id, .number = static_cast<std::uint16_t>(count + 1), .title = pane->foreground.view(), .cwd = pane->cwd.view()};
          if (features::nvim::find(session.nvim, pane->id) != nullptr) {
            fact.kind = PaneKind::editor;
            fact.title = "nvim";
          } else if (agent != nullptr) {
            fact.kind = PaneKind::agent;
            fact.title = !agent->display_name.view().empty() ? agent->display_name.view() : agent->provider_name.view();
          } else {
            fact.kind = isShell(fact.title) ? PaneKind::shell : PaneKind::program;
          }

          if (fact.title.empty()) {
            fact.title = "shell";
          }

          ++count;
        }

        for (const auto& workspace : session.workspaces()) {
          if (workspace.location.kind == tab->location.workspace.kind && workspace.location.id == tab->location.workspace.id) {
            context.workspace = workspace.path.view();
          }
        }
      }

      context.panes = panes.view().first(count);
      return std::forward<Use>(use)(context);
    }

    // Asks the runtime for what the windows of the machine lack, while it may ask for more.
    void reconcile(Session& session, View& view, const Host& host) {
      auto& state = session.explorer;

      while (session.ready() && feature::mayAsk(state)) {
        const auto need = feature::need(view, state, host.machine);
        if (!need) {
          return;
        }

        ds::Option<std::uint64_t> request;

        switch (need->kind) {
        case feature::NeedKind::listing:
          request = session.link.ask(feature::listing(state, need->path));
          break;
        case feature::NeedKind::sizes:
          request = session.link.ask(feature::measure(state, need->path));
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

        feature::asked(state, *need, *request);
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
      auto& state = session.explorer;

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
        ds::Array<FileOperation, FileLimits::maximum_operations> operations{};
        const auto count = feature::operations(view, host.machine, operations.viewMut());
        if (count == 0 || state.applying != 0) {
          return Effect::none;
        }

        if (const auto request = session.link.ask(ChangeFiles{.overwrite = action.overwrite, .operations = operations.view().first(count)})) {
          feature::applying(state, *request, false);
        }

        return Effect::none;
      }
      case ActionKind::undo:
        if (state.applying == 0) {
          if (const auto request = session.link.ask(UndoFileChanges{})) {
            feature::applying(state, *request, true);
          }
        }

        return Effect::none;
      case ActionKind::commit:
        if (state.committing == 0 && !view.windows.empty()) {
          if (const auto request = session.link.ask(CommitChanges{.path = feature::window(view).root.view(), .message = view.text.view()})) {
            feature::committing(state, *request);
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

    with(session, host, [&](const Context& context) {
      feature::open(view, session.explorer, context, host.machine);
    });
    reconcile(session, view, host);
    return true;
  }

  void close(View& view) noexcept {
    feature::close(view);
  }

  Effect press(Session& session, View& view, const Host& host, KeyChord chord) {
    const auto action = with(session, host, [&](const Context& context) {
      return feature::press(view, session.explorer, context, chord);
    });

    return finish(session, view, host, action);
  }

  void typed(Session& session, View& view, const Host& host, std::string_view text) {
    with(session, host, [&](const Context& context) {
      feature::typed(view, session.explorer, context, text);
    });
    reconcile(session, view, host);
  }

  Effect submit(Session& session, View& view, const Host& host, std::string_view text) {
    const auto action = with(session, host, [&](const Context& context) {
      return feature::submit(view, session.explorer, context, text);
    });

    return finish(session, view, host, action);
  }

  void cancel(Session& session, View& view, const Host& host) {
    with(session, host, [&](const Context& context) {
      feature::cancel(view, session.explorer, context);
    });
    reconcile(session, view, host);
  }

  void select(Session& session, View& view, const Host& host, std::size_t window, std::size_t row, bool extend, bool toggle) {
    with(session, host, [&](const Context& context) {
      feature::select(view, session.explorer, context, window, row, extend, toggle);
    });
    reconcile(session, view, host);
  }

  Effect activate(Session& session, View& view, const Host& host, std::size_t window, std::size_t row) {
    const auto action = with(session, host, [&](const Context& context) {
      return feature::activate(view, session.explorer, context, window, row);
    });

    return finish(session, view, host, action);
  }

  void toggle(Session& session, View& view, const Host& host, std::size_t window, std::size_t row) {
    with(session, host, [&](const Context& context) {
      feature::toggle(view, session.explorer, context, window, row);
    });
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

    with(session, host, [&](const Context& context) {
      const auto& state = session.explorer;

      feature::settle(view, state, context, host.machine);
      if (feature::follow(view, context, host.machine) || view.built != state.revision) {
        feature::rebuild(view, state, context, host.machine);
      }
    });
    reconcile(session, view, host);
    return view.revision != before;
  }

  RowLook look(const Session& session, const View& view, const Host& host, std::size_t window, std::size_t row) {
    return with(session, host, [&](const Context& context) {
      return feature::look(view, session.explorer, context, window, row);
    });
  }

  HeaderLook header(const Session& session, const View& view, const Host& host, std::size_t window) {
    return with(session, host, [&](const Context& context) {
      return feature::header(view, session.explorer, context, window);
    });
  }

  StatusLook status(const Session& session, const View& view, const Host& host, std::size_t window) {
    return with(session, host, [&](const Context& context) {
      return feature::status(view, session.explorer, context, window);
    });
  }

  Hints hints(const Session& session, const View& view, const Host& host) {
    return with(session, host, [&](const Context& context) {
      return feature::hints(view, session.explorer, context);
    });
  }

  ds::Array<LensLook, lens_count> lenses(const Session& session, const View& view, const Host& host) {
    return with(session, host, [&](const Context& context) {
      return feature::lenses(view, session.explorer, context);
    });
  }

  PreviewLook preview(const Session& session, const View& view, const Host& host, std::uint64_t now_seconds) {
    return with(session, host, [&](const Context& context) {
      return feature::preview(view, session.explorer, context, now_seconds);
    });
  }

}

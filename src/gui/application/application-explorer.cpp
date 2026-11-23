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

    using feature::PaneKind;

    constexpr bool isShell(std::string_view program) noexcept {
      constexpr ds::Array<std::string_view, 9> shells{"zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "nu", "pwsh"};

      return std::ranges::contains(shells, program);
    }

    // The agent the pane runs, if the runtime reports one there.
    tbc::val_a<const Agent<Memory>*> agentIn(tbc::ref_a<ds::Vec<Agent<Memory>, Memory>> agents, std::uint64_t pane) noexcept {
      for (const auto& agent : agents) {
        if (agent.pane_id == pane) {
          return &agent;
        }
      }

      return nullptr;
    }

    // What the pane runs, and the name it shows: an editor, an agent, a shell or another program.
    void name(Scene::Pane& kept, const Session& session, std::string_view foreground) {
      if (features::nvim::find(session.nvim, kept.id) != nullptr) {
        kept.kind = PaneKind::editor;
        kept.title.assign("nvim");
      } else if (const auto* agent = agentIn(session.agent_list.entries(), kept.id)) {
        kept.kind = PaneKind::agent;
        kept.title.assign(!agent->display_name.view().empty() ? agent->display_name.view() : agent->provider_name.view());
      } else {
        kept.kind = isShell(foreground) ? PaneKind::shell : PaneKind::program;
        kept.title.assign(foreground);
      }

      if (kept.title.empty()) {
        kept.title.assign("shell");
      }
    }

    // The place in `scene` for one machine more; none past what a window keeps.
    tbc::val_a<Scene::Machine*> place(tbc::mut_a<Scene> scene, const Host& host) {
      if (scene.machine_count == scene_machines) {
        return nullptr;
      }

      if (scene.machine_count == scene.machines.size()) {
        scene.machines.push(Scene::Machine{scene.workspace.memory()});
      }

      auto& kept = scene.machines.atMut(scene.machine_count++);

      kept.id = host.machine;
      kept.label.assign(host.name);
      kept.home.assign(host.home);
      kept.local = host.local;
      kept.reach = Reach::away;
      return &kept;
    }

    // Asks the runtime for what the windows of the machine lack, while it may ask for more.
    void reconcile(Session& session, const View& view, std::uint64_t machine) {
      // A runtime that does not speak of files is asked for nothing: its windows say so.
      if (!available(session)) {
        return;
      }

      session.explorer.finds = session.speaks(ClientTag::find_paths);
      while (session.ready()) {
        const auto need = feature::need(view, session.explorer, machine);
        // A search follows what is typed, and waits for no answer on files to be asked.
        const bool beside = need && (need->kind == feature::NeedKind::search || need->kind == feature::NeedKind::touches);

        if (!need || (!beside && !feature::mayAsk(session.explorer))) {
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
        case feature::NeedKind::home:
          request = session.link.ask(LocateHome{});
          break;
        case feature::NeedKind::touches:
          // Every touch the runtime keeps: a window shows the ones below its own root.
          request = session.link.ask(QueryTouches{.path = "/"});
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
    // named, from the focused one. False when none of them opened.
    bool edit(Session& session, const View& view, std::uint64_t pane) {
      if (pane == 0) {
        const auto* tab = activeTab(session.tabs, session.active_tab);

        pane = tab == nullptr ? 0 : tab->focused_pane;
      }

      bool opened = false;

      for (const auto& path : view.paths) {
        opened = nvim::edit(session, pane, {.path = path.view()}) || opened;
      }

      return opened;
    }

    // Sends the runtime of `machine` its part of the plan.
    void apply(Session& session, const View& view, std::uint64_t machine, bool overwrite) {
      feature::Operations operations{};
      const auto count = feature::operations(view, machine, operations);
      if (count == 0 || session.explorer.applying != 0) {
        return;
      }

      if (const auto request = session.link.ask(ChangeFiles{.overwrite = overwrite, .operations = operations.view().first(count)})) {
        feature::applying(session.explorer, *request, false);
      }
    }

  }

  Scene::Scene(Memory& made_in)
      : panes(made_in),
        machines(made_in),
        workspace(made_in) {}

  Scene::Pane::Pane(Memory& made_in)
      : title(made_in),
        cwd(made_in) {}

  Scene::Machine::Machine(Memory& made_in)
      : label(made_in),
        home(made_in) {}

  void clear(Scene& scene) noexcept {
    scene.machine_count = 0;
  }

  void observe(Scene& scene, const Session& session, std::uint64_t machine) {
    scene.shown = machine;
    scene.pane_count = 0;
    scene.focused = 0;
    scene.workspace.clear();

    const auto* tab = activeTab(session.tabs, session.active_tab);
    if (tab == nullptr) {
      return;
    }

    scene.focused = tab->focused_pane;
    // The panes the session holds of the tab, which it knows before the runtime lists them.
    for (const auto& pane : session.panes) {
      if (!sameTab(pane->location, tab->location) || pane->exited || scene.pane_count == scene_panes) {
        continue;
      }

      if (scene.pane_count == scene.panes.size()) {
        scene.panes.push(Scene::Pane{scene.workspace.memory()});
      }

      auto& kept = scene.panes.atMut(scene.pane_count);

      kept.id = pane->id;
      kept.number = static_cast<std::uint16_t>(++scene.pane_count);
      kept.cwd.assign(pane->cwd.view());
      name(kept, session, pane->foreground.view());
    }

    for (const auto& workspace : session.workspace_list.entries()) {
      if (workspace.location.kind == tab->location.workspace.kind && workspace.location.id == tab->location.workspace.id) {
        scene.workspace.assign(workspace.path.view());
      }
    }
  }

  void observe(Scene& scene, const Host& host, const Session& session) {
    auto* kept = place(scene, host);
    if (kept == nullptr) {
      return;
    }

    // What the runtime says of its home is what `~` stands for there, whatever ui believed.
    if (!session.explorer.home.empty()) {
      kept->home.assign(session.explorer.home.view());
    }

    if (session.ready()) {
      kept->reach = session.explores() ? Reach::answers : Reach::silent;
    }
  }

  void observe(Scene& scene, const Host& host) {
    static_cast<void>(place(scene, host));
  }

  tbc::val_a<Around> around(tbc::ref_a<Scene> scene) noexcept {
    Around result;

    result.focused = scene.focused;
    result.shown = scene.shown;
    result.now = scene.now;
    result.workspace = scene.workspace.view();
    result.pane_count = scene.pane_count;
    for (std::size_t index = 0; index < scene.pane_count; ++index) {
      const auto& kept = scene.panes[index];

      result.panes.atMut(index) = {.id = kept.id, .number = kept.number, .kind = kept.kind, .title = kept.title.view(), .cwd = kept.cwd.view()};
    }

    result.machine_count = scene.machine_count;
    for (std::size_t index = 0; index < scene.machine_count; ++index) {
      const auto& kept = scene.machines[index];

      result.machines.atMut(index) = {.id = kept.id, .label = kept.label.view(), .local = kept.local, .reach = kept.reach};
      result.homes.atMut(index) = kept.home.view();
    }

    return result;
  }

  tbc::val_a<Context> contextOf(tbc::ref_a<Around> around, std::uint64_t machine) noexcept {
    Context context{
        .panes = around.panes.view().first(around.pane_count),
        .focused = around.focused,
        .workspace = around.workspace,
        .now = around.now,
        .reach = Reach::away,
        .host = machine,
        .shown = around.shown,
        .machines = around.machines.view().first(around.machine_count),
    };

    for (std::size_t index = 0; index < around.machine_count; ++index) {
      const auto& known = around.machines[index];
      if (known.id == machine) {
        context.home = around.homes[index];
        context.machine = known.label;
        context.local = known.local;
        context.reach = known.reach;
      }
    }

    return context;
  }

  bool available(const Session& session) noexcept {
    return session.ready() && session.explores();
  }

  bool refresh(Session& session, View& view, const Context& context) {
    if (!view.open) {
      return false;
    }

    const auto before = view.revision;

    feature::settle(view, session.explorer, context, context.host);
    // A window follows a pane of the machine that shows, and of no other.
    if (context.host == context.shown && feature::follow(view, context, context.host)) {
      feature::rebuild(view, session.explorer, context, context.host);
    } else {
      feature::absorb(view, session.explorer, context, context.host);
    }

    reconcile(session, view, context.host);
    return view.revision != before;
  }

  namespace {

    using feature::TransferAsk;

    // Says where a file brought to this machine goes, once the machine's home is known: below
    // its downloads, in a directory of the machine it comes from. False while the home is not
    // known, which the runtime is then asked.
    bool place(Session& session, View& view, std::size_t index, const Context& context, std::uint64_t now_ms) {
      if (!view.transfers[index].directory.empty()) {
        return true;
      }

      // The home the window knows of the machine, or the one its runtime said.
      const auto home = context.home.empty() ? session.explorer.home.view() : context.home;
      if (!home.empty()) {
        const auto label = feature::labelOf(context, view.transfers[index].from);
        auto& directory = view.transfers.atMut(index).directory;

        directory.assign(home);
        directory.append("/Downloads/telar/");
        for (const char character : label) {
          // A label is no path: what would part it into two directories does not.
          directory.push(character == '/' || character == '\\' ? '-' : character);
        }

        return true;
      }

      if (session.explorer.located) {
        feature::giveUp(view, index, "its machine has no home to bring it to", now_ms);
      } else if (session.explorer.locating == 0) {
        const feature::Need wanted{.kind = feature::NeedKind::home};

        if (const auto request = session.link.ask(LocateHome{})) {
          feature::asked(session.explorer, wanted, *request);
        }
      }

      return false;
    }

    // Sends what the transfer asks of this session's runtime. Nothing when the queue is full:
    // the next time asks again.
    ds::Option<std::uint64_t> request(Session& session, const feature::Transfer& transfer, TransferAsk ask, bool joined) {
      ds::String<Memory> target{session.memory, transfer.directory.view()};

      target.append("/");
      target.append(transfer.name.view());
      switch (ask) {
      case TransferAsk::none:
        return ds::none;
      case TransferAsk::read:
        return session.link.ask(ReadFile{.path = transfer.source.view(), .identity = transfer.identity, .offset = transfer.done, .limit = FileLimits::chunk_bytes});
      case TransferAsk::write:
        return session.link.ask(WriteFile{.target = target.view(), .partial = transfer.partial.view(), .offset = transfer.done, .parents = transfer.kind == feature::TransferKind::bring, .bytes = transfer.chunk.view()});
      case TransferAsk::keep:
        return session.link.ask(EndFileWrite{.partial = transfer.partial.view(), .target = target.view(), .keep = true, .overwrite = transfer.overwrite, .joins = joined});
      case TransferAsk::drop:
        return session.link.ask(EndFileWrite{.partial = transfer.partial.view(), .target = target.view(), .keep = false});
      case TransferAsk::trash: {
        const ds::Array<FileOperation, 1> original{{{.kind = FileOperationKind::trash, .source = transfer.source.view(), .identity = transfer.identity}}};

        return session.link.ask(ChangeFiles{.operations = original.view(), .joins = joined});
      }
      }

      return ds::none;
    }

    // Types the path of a file that was brought at the pane that waited for it.
    void handBrought(Session& session, const feature::Transfer& transfer, std::string_view home) {
      ds::String<Memory> typed{session.memory};

      if (transfer.mention) {
        typed.append("@");
      }

      feature::appendTyped(typed, transfer.placed.view(), {.cwd = {}, .home = home, .shell = !transfer.mention});
      typed.append(" ");
      hand(session, transfer.pane, typed.view());
      if (transfer.mention) {
        workbench::focusPane(session, transfer.pane);
      }
    }

    // The machine a pass carries for, and when.
    struct Pass {
      std::uint64_t machine = 0;
      std::uint64_t now_ms = 0;
    };

    // Takes what this machine answered the request the transfer has in flight here.
    void collect(Session& session, View& view, std::size_t index, const Pass& pass) {
      if (feature::awaits(view.transfers[index]) != pass.machine) {
        return;
      }

      const auto waited = view.transfers[index].request;
      const auto epoch = view.transfers[index].epoch;

      if (epoch != session.explorer.epoch || !session.ready()) {
        feature::lose(view, index, pass.now_ms);
        return;
      }

      if (auto answer = feature::carried(session.explorer, waited)) {
        feature::take(view, index, answer.getMut(), pass.now_ms);
      }
    }

  }

  bool carry(Session& session, View& view, const Context& context, std::uint64_t now_ms) {
    const auto before = view.revision;
    const auto machine = context.host;

    for (std::size_t index = 0; index < view.transfers.size(); ++index) {
      collect(session, view, index, {.machine = machine, .now_ms = now_ms});
      static_cast<void>(feature::halt(view, index, now_ms));

      const auto asking = feature::asks(view, index);
      if (asking.machine != machine || asking.ask == TransferAsk::none) {
        continue;
      }

      if (!session.ready() || !session.explores()) {
        feature::giveUp(view, index, "its machine does not answer for files", now_ms);
        continue;
      }

      if (asking.ask == TransferAsk::write && !place(session, view, index, context, now_ms)) {
        continue;
      }

      const bool joined = feature::joins(view.begun, view.transfers[index].batch, machine);

      if (const auto sent = request(session, view.transfers[index], asking.ask, joined)) {
        feature::carrying(session.explorer, *sent);
        feature::asked(view.transfers.atMut(index), {.request = *sent, .epoch = session.explorer.epoch, .now_ms = now_ms});
      }
    }

    // A file brought for a pane of this machine is typed there once it is whole.
    for (std::size_t index = 0; index < view.transfers.size(); ++index) {
      const auto& transfer = view.transfers[index];
      const bool brought = transfer.kind == feature::TransferKind::bring && transfer.phase == feature::TransferPhase::arrived && !transfer.handed && transfer.to == machine;

      if (brought) {
        view.transfers.atMut(index).handed = true;
        handBrought(session, view.transfers[index], context.home);
      }
    }

    static_cast<void>(feature::sweep(view, now_ms));
    return view.revision != before;
  }

  Effect deliver(Session& session, View& view, const Context& context, const Action& action) {
    switch (action.kind) {
    case ActionKind::none:
    case ActionKind::apply:
    case ActionKind::undo:
    case ActionKind::commit:
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
      // The session of the machine the files are on opens them.
      return leave(view);
    case ActionKind::change_directory: {
      ds::String<Memory> command{session.memory, "cd "};

      feature::appendTyped(command, view.text.view(), {.cwd = {}, .home = context.home});
      session.runCommand(action.pane, command.view());
      return leave(view);
    }
    case ActionKind::split:
      static_cast<void>(workbench::splitAt(session, ClientLayoutAxis::horizontal, view.text.view()));
      return leave(view);
    case ActionKind::focus_pane:
      workbench::focusPane(session, action.pane);
      return leave(view);
    }

    return Effect::none;
  }

  bool send(Session& session, View& view, const Context& context, const Action& action) {
    switch (action.kind) {
    case ActionKind::none:
    case ActionKind::close:
    case ActionKind::copy:
    case ActionKind::insert:
    case ActionKind::mention:
    case ActionKind::change_directory:
    case ActionKind::split:
    case ActionKind::focus_pane:
      return true;
    case ActionKind::open:
      // From the pane the keys named when it is of this session, else from its focused one.
      if (action.machine == context.host && !edit(session, view, context.host == context.shown ? action.pane : 0)) {
        ds::String<Memory> said{session.memory};

        ds::formatTo(said, "No editor opens on {}: its runtime has none, or no tab to put it in", context.machine);
        feature::refuse(view, said.view());
        return false;
      }

      return true;
    case ActionKind::apply:
      apply(session, view, context.host, action.overwrite);
      return true;
    case ActionKind::undo:
      if (session.explorer.applying == 0 && std::ranges::contains(view.wrote, context.host)) {
        if (const auto request = session.link.ask(UndoFileChanges{})) {
          feature::applying(session.explorer, *request, true);
        }
      }

      return true;
    case ActionKind::commit:
      if (action.machine == context.host && session.explorer.committing == 0 && !view.windows.empty()) {
        if (const auto request = session.link.ask(CommitChanges{.path = feature::window(view).root.view(), .message = view.text.view()})) {
          feature::committing(session.explorer, *request);
        }
      }

      return true;
    }

    return true;
  }

}

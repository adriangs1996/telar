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

    // What a pane runs, the name it shows, the file its editor is on and what its agent is
    // doing: views of what the session holds.
    struct Named {
      PaneKind kind = PaneKind::shell;
      std::string_view title;
      std::string_view buffer;
      std::string_view state;
    };

    // An editor, an agent, a shell or another program.
    tbc::val_a<Named> named(tbc::ref_a<Session> session, std::uint64_t pane, tbc::val_a<std::string_view> foreground) {
      Named result{.kind = isShell(foreground) ? PaneKind::shell : PaneKind::program, .title = foreground};

      if (const auto* editor = features::nvim::find(session.nvim, pane)) {
        const std::string_view text{editor->files.text.data(), editor->files.text.size()};

        result.kind = PaneKind::editor;
        result.title = "nvim";
        for (const auto& file : editor->files.files) {
          if (file.current) {
            result.buffer = file.path.of(text);
          }
        }
      } else if (const auto* agent = agentIn(session.agent_list.entries(), pane)) {
        result.kind = PaneKind::agent;
        result.title = !agent->display_name.view().empty() ? agent->display_name.view() : agent->provider_name.view();
        result.state = agentStatusName(agent->status);
      }

      if (result.title.empty()) {
        result.title = "shell";
      }

      return result;
    }

    // A text more of the roster: where it is in the roster's own.
    feature::Slice keep(ds::Vec<char, Memory>& text, std::string_view piece) {
      const feature::Slice slice{.offset = static_cast<std::uint32_t>(text.size()), .size = static_cast<std::uint32_t>(piece.size())};

      text.extend(std::span<const char>{piece});
      return slice;
    }

    // The tabs whose panes the roster has counted, to say each pane's place in its own.
    struct Counted {
      static constexpr std::size_t tabs = 64;

      ds::Array<TabLocation, tabs> locations{};
      ds::Array<std::uint16_t, tabs> panes{};
      std::size_t count = 0;
    };

    // The place of one pane more in the tab at `location`, from one; 0 past the tabs counted.
    std::uint16_t placeIn(Counted& counted, const TabLocation& location) noexcept {
      for (std::size_t index = 0; index < counted.count; ++index) {
        if (sameTab(counted.locations[index], location)) {
          return ++counted.panes.atMut(index);
        }
      }

      if (counted.count == Counted::tabs) {
        return 0;
      }

      counted.locations.atMut(counted.count) = location;
      counted.panes.atMut(counted.count++) = 1;
      return 1;
    }

    // A pane of a session, as the roster lists it.
    struct Listed {
      std::uint64_t id = 0;
      TabLocation location;
      std::string_view foreground;
      std::string_view cwd;
    };

    void enroll(Scene& scene, const Session& session, std::uint64_t machine, const Listed& pane, Counted& counted) {
      const auto number = placeIn(counted, pane.location);

      if (scene.roster.size() == scene_roster || feature::docked(session.explorer, pane.id) != nullptr) {
        return;
      }

      const auto known = named(session, pane.id, pane.foreground);
      std::string_view workspace;

      for (const auto& listed : session.workspace_list.entries()) {
        if (listed.location.kind == pane.location.workspace.kind && listed.location.id == pane.location.workspace.id) {
          workspace = listed.name.view();
        }
      }

      scene.roster.push({
          .machine = machine,
          .id = pane.id,
          .number = number,
          .kind = known.kind,
          .title = keep(scene.roster_text, known.title),
          .cwd = keep(scene.roster_text, pane.cwd),
          .workspace = keep(scene.roster_text, workspace),
          .buffer = keep(scene.roster_text, known.buffer),
          .state = keep(scene.roster_text, known.state),
      });
    }

    // The panes of every tab of a machine's session: the ones it holds, in the order the tabs
    // number them, then the ones its runtime lists and it never showed, which have no directory.
    void observeRoster(Scene& scene, const Session& session, std::uint64_t machine) {
      Counted counted;

      for (const auto& pane : session.panes) {
        if (!pane->exited) {
          enroll(scene, session, machine, {.id = pane->id, .location = pane->location, .foreground = pane->foreground.view(), .cwd = pane->cwd.view()}, counted);
        }
      }

      for (const auto& listed : session.paneList()) {
        const bool held = std::ranges::any_of(session.panes, [&](const auto& pane) {
          return pane->id == listed.pane_id;
        });

        if (!held) {
          enroll(scene, session, machine, {.id = listed.pane_id, .location = listed.location, .foreground = listed.foreground.view()}, counted);
        }
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
      kept.workspace.clear();
      kept.agent = 0;
      kept.agent_cwd.clear();
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

    // `<C-w>T` over the panes: asks the runtime for a pane the explorer stands as, beside the
    // focused one, with the windows it has. The pane takes it when the runtime opens it.
    void stand(Session& session, View& view, const Context& context) {
      if (context.host != context.shown) {
        return;
      }

      if (!session.speaks(ClientTag::create_explorer_pane)) {
        feature::refuse(view, "This machine's runtime keeps no explorer as a pane; update telar there");
        return;
      }

      feature::KeptWindows windows{};
      const auto count = feature::keptWindows(windows, view, context);
      if (count == 0 || standing(session) != 0 || !workbench::splitExplorer(session, {.windows = windows.view().first(count), .current = static_cast<std::uint8_t>(view.current), .side_by_side = view.side_by_side})) {
        feature::refuse(view, "The explorer cannot stand beside the panes now");
        return;
      }

      view.moving = true;
      feature::say(view, "beside the panes · <C-w>T puts it over them again");
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
        workspace(made_in),
        edited_text(made_in),
        edited(made_in),
        roster_text(made_in),
        roster(made_in) {}

  Scene::Pane::Pane(Memory& made_in)
      : title(made_in),
        cwd(made_in),
        buffer(made_in) {}

  Scene::Machine::Machine(Memory& made_in)
      : label(made_in),
        home(made_in),
        workspace(made_in),
        agent_cwd(made_in) {}

  void clear(Scene& scene) noexcept {
    scene.machine_count = 0;
    scene.edited_text.clear();
    scene.edited.clear();
    scene.edited_revision = 0;
    scene.roster_text.clear();
    scene.roster.clear();
  }

  namespace {

    // The files the editors of a machine's session hold, whatever tab their panes are in.
    void observeEdited(Scene& scene, const Session& session, std::uint64_t machine) {
      scene.edited_revision += features::nvim::filesRevision(session.nvim);
      for (const auto& pane : session.panes) {
        const auto* editor = pane->exited ? nullptr : features::nvim::find(session.nvim, pane->id);
        if (editor == nullptr) {
          continue;
        }

        const std::string_view text{editor->files.text.data(), editor->files.text.size()};

        for (const auto& file : editor->files.files) {
          const auto path = file.path.of(text);

          scene.edited.push({.machine = machine, .pane = pane->id, .offset = static_cast<std::uint32_t>(scene.edited_text.size()), .size = static_cast<std::uint32_t>(path.size()), .modified = file.modified, .current = file.current});
          scene.edited_text.extend(std::span<const char>{path});
        }
      }
    }

  }

  namespace {

    // What a window on the session's machine acts in while another machine shows: the workspace
    // of the tab the session has in view, and the agent there a mention goes to, the focused
    // pane when it is one.
    void observeTab(Scene::Machine& kept, const Session& session) {
      const auto* tab = activeTab(session.tabs, session.active_tab);
      if (tab == nullptr) {
        return;
      }

      for (const auto& workspace : session.workspace_list.entries()) {
        if (workspace.location.kind == tab->location.workspace.kind && workspace.location.id == tab->location.workspace.id) {
          kept.workspace.assign(workspace.path.view());
        }
      }

      for (const auto& pane : session.panes) {
        const bool agent = sameTab(pane->location, tab->location) && !pane->exited && agentIn(session.agent_list.entries(), pane->id) != nullptr;
        if (agent && (kept.agent == 0 || pane->id == tab->focused_pane)) {
          kept.agent = pane->id;
          kept.agent_cwd.assign(pane->cwd.view());
        }
      }
    }

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

    const bool within = feature::docked(session.explorer, tab->focused_pane) != nullptr;
    bool accompanied = false;

    scene.focused = tab->focused_pane;
    // The panes the session holds of the tab, which it knows before the runtime lists them.
    for (const auto& pane : session.panes) {
      if (!sameTab(pane->location, tab->location) || pane->exited || scene.pane_count == scene_panes || feature::docked(session.explorer, pane->id) != nullptr) {
        continue;
      }

      accompanied = accompanied || pane->id == scene.companion;

      if (scene.pane_count == scene.panes.size()) {
        scene.panes.push(Scene::Pane{scene.workspace.memory()});
      }

      auto& kept = scene.panes.atMut(scene.pane_count);

      const auto known = named(session, pane->id, pane->foreground.view());

      kept.id = pane->id;
      kept.number = static_cast<std::uint16_t>(++scene.pane_count);
      kept.cwd.assign(pane->cwd.view());
      kept.kind = known.kind;
      kept.title.assign(known.title);
      kept.buffer.assign(known.buffer);
    }

    if (!within) {
      scene.companion = scene.focused;
    } else if (accompanied) {
      // The focus is in the explorer's own pane: the pane it came from stands for it.
      scene.focused = scene.companion;
    } else {
      // Or the first of the tab, when that one is gone.
      scene.focused = scene.pane_count == 0 ? 0 : scene.panes[0].id;
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

    observeTab(*kept, session);
    observeEdited(scene, session, host.machine);
    observeRoster(scene, session, host.machine);
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
    result.edited = {.text = std::string_view{scene.edited_text.data(), scene.edited_text.size()}, .files = scene.edited.view()};
    result.roster = {.text = std::string_view{scene.roster_text.data(), scene.roster_text.size()}, .panes = scene.roster.view()};
    result.pane_count = scene.pane_count;
    for (std::size_t index = 0; index < scene.pane_count; ++index) {
      const auto& kept = scene.panes[index];

      result.panes.atMut(index) = {.id = kept.id, .number = kept.number, .kind = kept.kind, .title = kept.title.view(), .cwd = kept.cwd.view(), .buffer = kept.buffer.view()};
    }

    result.machine_count = scene.machine_count;
    for (std::size_t index = 0; index < scene.machine_count; ++index) {
      const auto& kept = scene.machines[index];

      result.machines.atMut(index) = {.id = kept.id, .label = kept.label.view(), .local = kept.local, .reach = kept.reach, .workspace = kept.workspace.view(), .agent = kept.agent, .agent_cwd = kept.agent_cwd.view()};
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
        .edited = around.edited,
        .roster = around.roster,
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

  namespace {

    // The marks and the jump list outlive the window in the runtime of the machine it runs on:
    // it is asked for them once, they are taken when it answers, and it is given them again
    // when they changed, which no key does that only moves the cursor.
    void remember(Session& session, View& view, const Context& context) {
      if (!context.local || !available(session)) {
        return;
      }

      auto& state = session.explorer;
      if (state.recall == feature::Recall::unasked) {
        if (const auto request = session.link.ask(QueryPlaces{})) {
          feature::recalling(state, *request);
        }

        return;
      }

      feature::recall(view, state, context);
      if (state.recall != feature::Recall::taken || !feature::unkept(view)) {
        return;
      }

      ds::Vec<KeptPlace, Memory> places{view.memory};
      const auto jump = feature::keeping(places, view, context);

      session.link.send(KeepPlaces{.places = places.view(), .jump = jump});
      view.places_kept = view.places;
    }

  }

  std::uint64_t standing(const Session& session) noexcept {
    const auto* tab = activeTab(session.tabs, session.active_tab);
    if (tab == nullptr) {
      return 0;
    }

    for (const auto& docked : session.explorer.docked) {
      const auto* pane = findPane(session.panes, docked->pane);

      if (pane != nullptr && !pane->exited && !workbench::closing(session, docked->pane) && sameTab(pane->location, tab->location) && tab->layout.contains(pane->id)) {
        return pane->id;
      }
    }

    return 0;
  }

  namespace {

    // Gives the runtime the windows of the explorer for the pane it stands as, when where they
    // are changed since it was last given them, or whatever changed when `leaving`.
    void keep(Session& session, View& view, const Context& context, bool leaving) {
      const auto mark = feature::keptMark(view);
      const auto* pane = findPane(session.panes, view.host);
      if (pane == nullptr || pane->exited || view.windows.empty() || (!leaving && mark == view.kept_mark)) {
        return;
      }

      feature::KeptWindows windows{};
      const auto count = feature::keptWindows(windows, view, context);

      session.link.send(KeepExplorer{.pane_id = view.host, .layout = {.windows = windows.view().first(count), .current = static_cast<std::uint8_t>(view.current), .side_by_side = view.side_by_side}});
      view.kept_mark = mark;
    }

    // The explorer stands as `pane`: with the windows it has when it asked for the pane, and
    // otherwise with the ones the runtime keeps of it.
    void take(const Session& session, View& view, const Context& context, std::uint64_t pane) {
      const auto* docked = feature::docked(session.explorer, pane);

      if (!view.moving && docked != nullptr && !docked->kept.empty()) {
        ds::Array<Byte, FileLimits::explorer_windows * sizeof(ExplorerWindow)> scratch; // NOLINT(cppcoreguidelines-pro-type-member-init): the decoder writes the windows it hands back, so zeroing them first would be waste
        DecodeStorage storage{scratch.viewMut()};

        feature::restore(view, context, Codec::decode<ExplorerKept>(docked->kept.view(), storage).layout);
      }

      if (!view.open || view.windows.empty()) {
        feature::open(view, session.explorer, context, context.host);
      }

      view.moving = false;
      view.host = pane;
      feature::pin(view, true);
      // What it has is what its runtime keeps, until a window moves.
      view.kept_mark = feature::keptMark(view);
    }

  }

  Stood host(Session& session, View& view, const Context& context) {
    const auto pane = standing(session);
    const auto* tab = activeTab(session.tabs, session.active_tab);
    // Read before the session is told anything.
    const bool focused = pane != 0 && tab != nullptr && tab->focused_pane == pane;

    if (pane == 0) {
      if (view.host == 0) {
        return Stood::same;
      }

      // Its pane is gone, or is of a tab that no longer shows: the runtime is told where its
      // windows were left, if the pane is still there to keep them.
      keep(session, view, context, true);
      view.host = 0;
      feature::pin(view, false);
      feature::close(view);
      return Stood::left;
    }

    // Closed while its pane stands, it is taken again: a pane of the tab is never left empty.
    const bool taken = view.host != pane || !view.open;

    if (taken) {
      if (view.host != 0 && view.host != pane) {
        keep(session, view, context, true);
      }

      take(session, view, context, pane);
    }

    if (view.focused != focused) {
      feature::focus(view, focused);
      // The keys left it: the runtime keeps the row it was on.
      keep(session, view, context, !focused);
    } else {
      keep(session, view, context, false);
    }

    return taken ? Stood::taken : Stood::same;
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

    remember(session, view, context);
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
      ds::String<Memory> path{session.memory};

      feature::pathOf(path, transfer, ask);
      switch (ask) {
      case TransferAsk::none:
      case TransferAsk::list:
        // A listing is the cache's to ask for, as any directory a window shows.
        return ds::none;
      case TransferAsk::read:
        return session.link.ask(ReadFile{.path = path.view(), .identity = feature::readIdentity(transfer), .offset = transfer.done, .limit = FileLimits::chunk_bytes, .link = transfer.link});
      case TransferAsk::write:
        return session.link.ask(WriteFile{.target = path.view(), .partial = transfer.partial.view(), .offset = transfer.done, .parents = transfer.kind == feature::TransferKind::bring, .bytes = transfer.chunk.view()});
      case TransferAsk::keep:
        return session.link.ask(EndFileWrite{.partial = transfer.partial.view(), .target = path.view(), .keep = true, .overwrite = transfer.overwrite, .joins = joined});
      case TransferAsk::drop:
        return session.link.ask(EndFileWrite{.partial = transfer.partial.view(), .target = path.view(), .keep = false});
      case TransferAsk::make: {
        const ds::Array<FileOperation, 1> made{{{.kind = FileOperationKind::create_directory, .target = path.view()}}};

        // What is brought for a pane goes below the downloads, where nothing may be yet.
        return session.link.ask(ChangeFiles{.operations = made.view(), .joins = joined, .parents = transfer.kind == feature::TransferKind::bring});
      }
      case TransferAsk::link: {
        // What the link says is the chunk that was read of it, as text.
        const auto said = transfer.chunk.view();
        const std::string_view text{reinterpret_cast<const char*>(said.data()), said.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): char may alias the bytes, and no cast-free view reads them as text
        const ds::Array<FileOperation, 1> linked{{{.kind = FileOperationKind::link, .source = text, .target = path.view()}}};

        return session.link.ask(ChangeFiles{.operations = linked.view(), .joins = joined});
      }
      case TransferAsk::clear: {
        const ds::Array<FileOperation, 1> cleared{{{.kind = FileOperationKind::trash, .source = path.view()}}};

        return session.link.ask(ChangeFiles{.operations = cleared.view(), .joins = joined});
      }
      case TransferAsk::trash: {
        const ds::Array<FileOperation, 1> original{{{.kind = FileOperationKind::trash, .source = path.view(), .identity = transfer.identity}}};

        return session.link.ask(ChangeFiles{.operations = original.view(), .joins = joined});
      }
      }

      return ds::none;
    }

    // Reads the directory a tree's walk is in, as it is now, through the cache of its machine: a
    // page at a time, and once it is whole the walk takes it.
    void list(Session& session, View& view, std::size_t index, std::uint64_t now_ms) {
      ds::String<Memory> path{session.memory};

      feature::pathOf(path, view.transfers[index], TransferAsk::list);
      if (!view.transfers[index].fresh) {
        feature::relist(session.explorer, path.view());
        view.transfers.atMut(index).fresh = true;
      }

      const feature::Need wanted{.kind = feature::NeedKind::listing, .path = path.view()};
      const auto* directory = feature::find(session.explorer, path.view());

      if (directory != nullptr && directory->failed) {
        feature::giveUp(view, index, "a directory of it cannot be read", now_ms);
      } else if (feature::lacks(session.explorer, wanted)) {
        if (feature::mayAsk(session.explorer)) {
          if (const auto request = session.link.ask(feature::listing(session.explorer, path.view()))) {
            feature::asked(session.explorer, wanted, *request);
          }
        }
      } else if (directory != nullptr && directory->listing == 0 && !directory->stale) {
        feature::walked(view, index, *directory, now_ms);
      }
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

      if (asking.ask == TransferAsk::list) {
        list(session, view, index, now_ms);
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
      // As a pane it closes with its pane.
      if (view.host != 0) {
        static_cast<void>(workbench::closePane(session, view.host));
        view.host = 0;
        feature::pin(view, false);
      }

      feature::close(view);
      return Effect::closed;
    case ActionKind::pin:
      stand(session, view, context);
      return Effect::none;
    case ActionKind::unpin:
      // Over the panes again, with the windows it had: its pane closes.
      if (view.host != 0 && workbench::closePane(session, view.host)) {
        view.host = 0;
        feature::pin(view, false);
        feature::say(view, "over the panes");
      }

      return Effect::none;
    case ActionKind::copy:
      return Effect::copy;
    case ActionKind::insert:
    case ActionKind::mention:
      // One for the tab of another machine was handed over by that machine's session.
      if (action.machine == 0 || action.machine == context.shown) {
        hand(session, action.pane, view.text.view());
        if (action.kind == ActionKind::mention) {
          workbench::focusPane(session, action.pane);
        }
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
      if (action.machine == 0 || action.machine == context.shown) {
        static_cast<void>(workbench::splitAt(session, ClientLayoutAxis::horizontal, view.text.view()));
      }

      return leave(view);
    case ActionKind::focus_pane:
      // A pane of another machine was given the focus by that machine's session.
      if (action.machine == 0 || action.machine == context.shown) {
        workbench::focusPane(session, action.pane);
      }

      return leave(view);
    }

    return Effect::none;
  }

  namespace {

    // Whether an action is for the machine of the context while another one shows: the session
    // of that machine does it, which the one that shows cannot.
    constexpr bool elsewhere(const Context& context, const Action& action) noexcept {
      return action.machine == context.host && context.host != context.shown;
    }

  }

  bool send(Session& session, View& view, const Context& context, const Action& action) {
    switch (action.kind) {
    case ActionKind::none:
    case ActionKind::close:
    case ActionKind::copy:
    case ActionKind::insert:
    case ActionKind::change_directory:
    case ActionKind::pin:
    case ActionKind::unpin:
      return true;
    case ActionKind::focus_pane:
      // A pane the lens of panes listed of this machine, while another one shows: its tab comes
      // into view here, for whoever drives the explorer to show this machine.
      if (elsewhere(context, action)) {
        workbench::focusPane(session, action.pane);
      }

      return true;
    case ActionKind::mention:
      // From a window that is not on the machine that shows: the agent of the tab this machine
      // has in view takes it.
      if (elsewhere(context, action)) {
        hand(session, action.pane, view.text.view());
      }

      return true;
    case ActionKind::split:
      if (elsewhere(context, action) && !workbench::splitAt(session, ClientLayoutAxis::horizontal, view.text.view())) {
        ds::String<Memory> said{session.memory};

        ds::formatTo(said, "No shell opens on {}: it has no tab in view to put it in", context.machine);
        feature::refuse(view, said.view());
        return false;
      }

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

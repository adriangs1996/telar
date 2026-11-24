#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "explorer_controller.hpp"
#include "ui/kit/input/key_adapter.hpp"
#include "ui/kit/models/glyph_icon.hpp"
#include "ui/kit/models/projection.hpp"
#include <QClipboard>
#include <QDateTime>
#include <QDir>
#include <QDrag>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QStandardPaths>
#include <QVarLengthArray>
#include <QVariantList>
#include <algorithm>
#include <chrono>
#include <exception>
#include <string_view>
#include <utility>

import telar.gui.application;
import telar.gui.foundation.icons;
import telar.gui.foundation.system;

namespace telar::gui::qt {
  namespace {

    namespace explorer = application::explorer;

    using explorer::DiffTone;
    using explorer::Effect;
    using explorer::FileState;
    using explorer::Mode;
    using explorer::RowKind;

    constexpr ds::Array<const char*, 8> kind_names{"entry", "added", "header", "note", "diff", "change", "pane", "match"};
    constexpr ds::Array<const char*, 4> diff_tones{"context", "added", "removed", "hunk"};
    constexpr ds::Array<const char*, 9> mode_names{"normal", "visual", "insert", "search", "command", "plan", "help", "menu", "question"};
    // How often the transfers are looked at again with nothing arriving.
    constexpr int transfers_tick_ms = 250;
    constexpr ds::Array<const char*, 3> tone_names{"info", "error", "ask"};
    // Where the caret stands in a name that starts being typed, in the order of explorer::Caret.
    constexpr ds::Array<const char*, 4> caret_names{"stem", "all", "start", "end"};
    constexpr ds::Array<const char*, 3> follow_scopes{"pane", "workspace", "machine"};
    constexpr ds::Array<const char*, 4> actor_tones{"you", "claude", "codex", "agent"};
    // How an editor holds a row's file, in the order of explorer::Hold.
    constexpr ds::Array<const char*, 3> editor_holds{"", "open", "unsaved"};

    // The lines of a preview's text the window draws.
    constexpr qsizetype preview_lines = 200;
    constexpr double whole_share = 1000;

    template <std::size_t Capacity>
    QString fixedText(const runtime::FixedText<Capacity>& value) {
      return toQString(value.view());
    }

    // The chips of who touched a file: what each says, and whose color it has.
    QVariantList actorChips(std::span<const explorer::ActorLook> actors) {
      QVariantList result;

      for (const auto& actor : actors) {
        result.push_back(QVariantMap{{QStringLiteral("chip"), fixedText(actor.chip)}, {QStringLiteral("tone"), QString::fromLatin1(actor_tones[static_cast<std::size_t>(actor.tone)])}});
      }

      return result;
    }

    // The letter git's short status gives a state; a file it does not track has `?` in both columns.
    QString letter(FileState state) {
      switch (state) {
      case FileState::modified:
        return QStringLiteral("M");
      case FileState::added:
        return QStringLiteral("A");
      case FileState::deleted:
        return QStringLiteral("D");
      case FileState::renamed:
        return QStringLiteral("R");
      case FileState::untracked:
        return QStringLiteral("?");
      case FileState::conflicted:
        return QStringLiteral("!");
      case FileState::unchanged:
      case FileState::ignored:
        break;
      }

      return {};
    }

    QVariantList numbers(std::span<const std::uint16_t> values) {
      QVariantList result;

      for (const auto value : values) {
        result.push_back(static_cast<int>(value));
      }

      return result;
    }

    // A key a hint spells by its name, as the help does: `<CR>`, `<Esc>`, `<C-w>`.
    struct NamedKey {
      QLatin1StringView name;
      int key = 0;
      int modifiers = 0;
      QLatin1StringView text;
    };

    constexpr ds::Array<NamedKey, 3> named_keys{
        {
            {.name = QLatin1StringView{"<CR>"}, .key = Qt::Key_Return},
            {.name = QLatin1StringView{"<Esc>"}, .key = Qt::Key_Escape},
            {.name = QLatin1StringView{"<C-w>"}, .key = Qt::Key_W, .modifiers = static_cast<int>(NativeKeyAdapter::control_modifier), .text = QLatin1StringView{"w"}},
        },
    };

    const NamedKey* namedKey(QStringView spelled) noexcept {
      for (const auto& known : named_keys) {
        if (spelled == known.name) {
          return &known;
        }
      }

      return nullptr;
    }

    // A row of a window as QML names it; a row below zero is the window itself.
    explorer::Pick pickOf(int window, int row) noexcept {
      return {.window = static_cast<std::size_t>(window), .row = row < 0 ? std::numeric_limits<std::size_t>::max() : static_cast<std::size_t>(row)};
    }

    QVariantList helpGroups(const explorer::Help& help) {
      QVariantList result;
      QVariantList keys;
      std::string_view group;
      const auto close = [&] {
        if (!keys.isEmpty()) {
          result.push_back(QVariantMap{{QStringLiteral("title"), toQString(group)}, {QStringLiteral("keys"), keys}});
          keys.clear();
        }
      };

      // The lines of a group follow one another.
      for (const auto& line : help.lines.view().first(help.count)) {
        if (std::string_view{line.group} != group) {
          close();
          group = line.group;
        }

        keys.push_back(QVariantMap{{QStringLiteral("keys"), fixedText(line.keys)}, {QStringLiteral("label"), toQString(line.label)}});
      }

      close();
      return result;
    }

    // The number the explorer's windows carry for the machine in a slot of the window: never 0.
    constexpr std::uint64_t explorerMachine(std::size_t slot) noexcept {
      return static_cast<std::uint64_t>(slot) + 1;
    }

    // The session of the machine in `slot`, if the window holds a client for it.
    tbc::val_a<const GuiSession*> explorerSession(tbc::ref_a<Store> store, std::size_t slot) noexcept {
      const auto& clients = store.clients();

      return slot < clients.size() && clients[slot] ? &(*clients[slot])->session : nullptr;
    }

    tbc::val_a<GuiSession*> explorerSessionMut(tbc::mut_a<Store> store, std::size_t slot) noexcept {
      return explorerSession(store, slot) == nullptr ? nullptr : &store.clientMut(static_cast<application::machines::Machines::Slot>(slot)).session;
    }

    // The cache a use case changes on the machine of its window: the one its session holds, or
    // `away`, which holds nothing, for a machine the window has no client for.
    tbc::val_a<explorer::State&> explorerCacheMut(tbc::mut_a<Store> store, tbc::mut_a<explorer::State> away, std::uint64_t machine) noexcept {
      auto* session = machine == 0 ? nullptr : explorerSessionMut(store, static_cast<std::size_t>(machine - 1));

      return session == nullptr ? away : session->explorer;
    }

    // Whether the window keeps a machine in `slot`.
    bool keepsMachine(const Store& store, std::size_t slot) noexcept {
      const auto rows = store.machines().rows();

      return slot < rows.size() && rows[slot].used;
    }

  }

  ExplorerController::ExplorerController(Store& store, ApplicationAllocator& memory, QObject* parent)
      : QObject(parent),
        store_(store),
        view_(memory),
        promised_(memory),
        waited_(memory),
        outside_(platform::file_promises ? explorer::Outside::promises : explorer::Outside::caches),
        drag_cache_(QStandardPaths::writableLocation(QStandardPaths::CacheLocation) + QStringLiteral("/dragged")),
        home_(QDir::homePath().toUtf8()),
        scene_(memory),
        away_(memory) {
    // A model an invokable hands to QML with no parent would be the engine's to delete.
    for (auto& model : rows_.viewMut()) {
      model.setParent(this);
    }

    transfers_tick_.setInterval(transfers_tick_ms);
    connect(&transfers_tick_, &QTimer::timeout, this, &ExplorerController::synchronize);
  }

  void ExplorerController::observe() {
    const auto& machines = store_.machines();
    const auto rows = machines.rows();

    shown_ = machines.active();
    // The keys are the ones of the configuration as it is now: a reload changes them here.
    if (explorer::configure(view_, store_.session().configuration.explorer_keys)) {
      emit helpChanged();
    }

    explorer::clear(scene_);
    scene_.now = static_cast<std::uint64_t>(QDateTime::currentSecsSinceEpoch());
    explorer::observe(scene_, store_.session(), explorerMachine(shown_));
    for (std::size_t slot = 0; slot < rows.size(); ++slot) {
      if (!rows[slot].used) {
        continue;
      }

      const bool local = slot == application::machines::Machines::local_slot;
      const explorer::Host host{
          .machine = explorerMachine(slot),
          .name = rows[slot].label.view(),
          // The home of another machine's account is what its runtime says, once it does.
          .home = local ? std::string_view{home_.constData(), static_cast<std::size_t>(home_.size())} : std::string_view{},
          .local = local,
      };

      if (const auto* session = explorerSession(store_, slot)) {
        explorer::observe(scene_, host, *session);
      } else {
        explorer::observe(scene_, host);
      }
    }
  }

  const explorer::State& ExplorerController::cacheOf(std::uint64_t machine) const noexcept {
    const auto* session = machine == 0 ? nullptr : explorerSession(store_, static_cast<std::size_t>(machine - 1));

    return session == nullptr ? away_ : session->explorer;
  }

  std::uint64_t ExplorerController::machineOf(std::size_t window) const noexcept {
    return window < view_.windows.size() ? view_.windows[window]->machine : scene_.shown;
  }

  bool ExplorerController::refresh() {
    const auto around = explorer::around(scene_);
    const auto machines = store_.machines().rows().size();
    const auto before = view_.revision;

    for (std::size_t slot = 0; slot < machines; ++slot) {
      if (!keepsMachine(store_, slot)) {
        continue;
      }

      const auto context = explorer::contextOf(around, explorerMachine(slot));

      if (auto* session = explorerSessionMut(store_, slot)) {
        static_cast<void>(explorer::refresh(*session, view_, context));
      } else {
        // A machine that is away shows what its windows say of it, from a cache that holds nothing.
        explorer::absorb(view_, away_, context, context.host);
      }
    }

    return view_.revision != before;
  }

  bool ExplorerController::available() const {
    return explorer::available(store_.session());
  }

  bool ExplorerController::showing() const {
    return view_.open;
  }

  bool ExplorerController::pinned() const {
    return view_.pinned;
  }

  bool ExplorerController::focused() const {
    return view_.open && view_.focused;
  }

  bool ExplorerController::takes(explorer::Side side) {
    if (!view_.open || !view_.pinned || !view_.focused || !explorer::toward(view_, side)) {
      return false;
    }

    revision_ = view_.revision;
    publish();
    emit changed();
    return true;
  }

  void ExplorerController::claimFocus() {
    if (view_.open && view_.host != 0 && !view_.focused) {
      application::workbench::focusPane(store_.sessionMut(), view_.host);
      store_.touch();
    }
  }

  bool ExplorerController::sideBySide() const {
    return view_.side_by_side;
  }

  QAbstractItemModel* ExplorerController::rows(int window) {
    return window >= 0 && static_cast<std::size_t>(window) < rows_.size() ? &rows_.atMut(static_cast<std::size_t>(window)) : nullptr;
  }

  QVariantList ExplorerController::describeWindows(const explorer::Around& around) const {
    QVariantList result;

    for (std::size_t index = 0; index < view_.windows.size(); ++index) {
      const auto& window = *view_.windows[index];
      const auto& cache = cacheOf(window.machine);
      const auto context = explorer::contextOf(around, window.machine);
      const auto header = explorer::header(view_, cache, context, index);
      const auto status = explorer::status(view_, cache, context, index);

      result.push_back(QVariantMap{
          {QStringLiteral("index"), static_cast<int>(index)},
          {QStringLiteral("current"), status.current},
          {QStringLiteral("machine"), fixedText(header.machine)},
          {QStringLiteral("local"), header.local},
          {QStringLiteral("lead"), fixedText(header.lead)},
          {QStringLiteral("last"), fixedText(header.last)},
          {QStringLiteral("repository"), header.repository},
          {QStringLiteral("branch"), fixedText(header.branch)},
          {QStringLiteral("distance"), fixedText(header.distance)},
          {QStringLiteral("away"), header.away},
          {QStringLiteral("staged"), header.staged},
          {QStringLiteral("unstaged"), header.unstaged},
          {QStringLiteral("untracked"), header.untracked},
          {QStringLiteral("mode"), toQString(status.mode)},
          {QStringLiteral("modeKind"), QString::fromLatin1(mode_names[static_cast<std::size_t>(status.kind)])},
          {QStringLiteral("following"), fixedText(status.following)},
          {QStringLiteral("rootMachine"), fixedText(status.machine)},
          {QStringLiteral("follows"), status.follows},
          {QStringLiteral("root"), fixedText(status.root)},
          {QStringLiteral("rootPath"), toQString(window.root.view())},
          {QStringLiteral("pending"), status.pending},
          {QStringLiteral("flags"), fixedText(status.flags)},
          {QStringLiteral("filter"), fixedText(status.filter)},
          {QStringLiteral("total"), fixedText(status.total)},
          {QStringLiteral("keys"), fixedText(status.keys)},
          {QStringLiteral("chosen"), status.chosen},
          {QStringLiteral("carried"), status.carried},
          {QStringLiteral("position"), status.position},
          {QStringLiteral("count"), status.count},
          {QStringLiteral("loading"), window.loading},
          {QStringLiteral("hiddenEntries"), window.hidden_entries},
          {QStringLiteral("ignoredEntries"), window.ignored_entries},
          {QStringLiteral("top"), static_cast<int>(window.top)},
          {QStringLiteral("rows"), static_cast<int>(window.rows.size())},
          {QStringLiteral("page"), static_cast<int>(window.page)},
          {QStringLiteral("lens"), static_cast<int>(window.lens)},
      });
    }

    return result;
  }

  QVariantList ExplorerController::describeLenses(const explorer::Around& around) const {
    QVariantList result;

    if (view_.windows.empty()) {
      return result;
    }

    const auto machine = machineOf(view_.current);

    for (const auto& lens : explorer::lenses(view_, cacheOf(machine), explorer::contextOf(around, machine))) {
      result.push_back(QVariantMap{
          {QStringLiteral("name"), toQString(lens.name)},
          {QStringLiteral("count"), lens.count},
          {QStringLiteral("counted"), lens.counted},
          {QStringLiteral("current"), lens.current},
      });
    }

    return result;
  }

  QString ExplorerController::scope() const {
    if (view_.windows.empty()) {
      return {};
    }

    const auto& window = *view_.windows[view_.current];

    return window.follow ? QString::fromLatin1(follow_scopes[static_cast<std::size_t>(window.scope)]) : QString{};
  }

  QVariantMap ExplorerController::describeLine() const {
    QVariantMap result{
        {QStringLiteral("mode"), QString::fromLatin1(mode_names[static_cast<std::size_t>(view_.mode)])},
        {QStringLiteral("message"), view_.message.view().empty() ? toQString(explorer::idle_message) : fixedText(view_.message)},
        // What it says now, and nothing when it says nothing: a line being typed shows it beside itself.
        {QStringLiteral("said"), fixedText(view_.message)},
        {QStringLiteral("tone"), QString::fromLatin1(tone_names[static_cast<std::size_t>(view_.tone)])},
        {QStringLiteral("prefill"), toQString(view_.mode == Mode::insert ? view_.draft.view() : view_.prefill.view())},
        {QStringLiteral("caret"), QString::fromLatin1(caret_names[static_cast<std::size_t>(view_.caret)])},
        {QStringLiteral("overwrite"), view_.overwrite},
        {QStringLiteral("edits"), static_cast<int>(view_.edits.size())},
        {QStringLiteral("revision"), static_cast<qulonglong>(view_.revision)},
        // The command line `<Tab>` completed, and how many times it did: the field takes it when
        // the count grows.
        {QStringLiteral("completion"), toQString(view_.completion.view())},
        {QStringLiteral("completed"), static_cast<int>(view_.completed)},
    };

    if (!view_.windows.empty()) {
      const auto& window = *view_.windows[view_.current];

      result.insert(QStringLiteral("window"), static_cast<int>(view_.current));
      result.insert(QStringLiteral("cursor"), static_cast<int>(window.cursor));
      result.insert(QStringLiteral("filter"), toQString(window.filter.view()));
    }

    return result;
  }

  QVariantList ExplorerController::describeHints(const explorer::Around& around) const {
    QVariantList result;

    if (view_.windows.empty()) {
      return result;
    }

    const auto machine = machineOf(view_.current);
    const auto hints = explorer::hints(view_, cacheOf(machine), explorer::contextOf(around, machine));

    for (std::size_t index = 0; index < hints.count; ++index) {
      const auto& hint = hints.items[index];

      result.push_back(QVariantMap{{QStringLiteral("keys"), fixedText(hint.keys)}, {QStringLiteral("label"), fixedText(hint.label)}, {QStringLiteral("enabled"), hint.enabled}});
    }

    return result;
  }

  QVariantMap ExplorerController::describePreview(const explorer::Around& around) const {
    if (view_.windows.empty()) {
      return {};
    }

    const auto machine = machineOf(view_.current);
    const auto& cache = cacheOf(machine);
    const auto look = explorer::preview(view_, cache, explorer::contextOf(around, machine), static_cast<std::uint64_t>(QDateTime::currentSecsSinceEpoch()));
    if (!look.shown) {
      return {{QStringLiteral("shown"), false}};
    }

    QVariantList facts;

    for (std::size_t index = 0; index < look.fact_count; ++index) {
      const auto& fact = look.facts[index];

      facts.push_back(QVariantMap{
          {QStringLiteral("label"), toQString(fact.label)},
          {QStringLiteral("value"), fixedText(fact.value)},
          {QStringLiteral("detail"), fixedText(fact.detail)},
          {QStringLiteral("added"), fact.added},
          {QStringLiteral("removed"), fact.removed},
      });
    }

    // The text a line at a time, each with what it is in a diff.
    QVariantList lines;
    auto rest = explorer::previewText(view_, cache);

    while (!rest.empty() && lines.size() < preview_lines) {
      const auto end = rest.find('\n');
      const auto line = rest.substr(0, end);
      const auto tone = look.diff ? explorer::toneOf(line) : DiffTone::context;

      lines.push_back(QVariantMap{{QStringLiteral("text"), toQString(line)}, {QStringLiteral("tone"), QString::fromLatin1(diff_tones[static_cast<std::size_t>(tone)])}});
      rest.remove_prefix(end == std::string_view::npos ? rest.size() : end + 1);
    }

    // Who touched the file lately.
    QVariantList activity;

    for (const auto& touch : look.activity.view().first(look.activity_count)) {
      activity.push_back(QVariantMap{
          {QStringLiteral("actors"), actorChips({&touch.actor, 1})},
          {QStringLiteral("who"), fixedText(touch.who)},
          {QStringLiteral("verb"), fixedText(touch.verb)},
          {QStringLiteral("ago"), fixedText(touch.ago)},
      });
    }

    // The heaviest of what a directory holds.
    QVariantList heavy;
    constexpr double hundredths = 100;

    for (const auto& entry : look.heavy.view().first(look.heavy_count)) {
      heavy.push_back(QVariantMap{
          {QStringLiteral("name"), fixedText(entry.name) + (entry.directory ? QStringLiteral("/") : QString{})},
          {QStringLiteral("tag"), toQString(entry.tag)},
          {QStringLiteral("size"), fixedText(entry.size)},
          {QStringLiteral("share"), entry.share / hundredths},
      });
    }

    QVariantMap result{
        {QStringLiteral("shown"), true},
        {QStringLiteral("activity"), activity},
        {QStringLiteral("heavy"), heavy},
        {QStringLiteral("directory"), look.directory},
        {QStringLiteral("name"), fixedText(look.name)},
        {QStringLiteral("path"), fixedText(look.path)},
        {QStringLiteral("facts"), facts},
        {QStringLiteral("panes"), numbers(look.panes.view().first(look.pane_count))},
        {QStringLiteral("title"), toQString(look.title)},
        {QStringLiteral("lines"), lines},
        {QStringLiteral("diff"), look.diff},
        {QStringLiteral("waiting"), look.waiting},
        {QStringLiteral("note"), toQString(look.note)},
    };

    // A pane is no file: its preview has no icon.
    if (look.kind != RowKind::pane) {
      putIcon(result, look.directory ? directoryIcon() : fileIcon(look.name.view()));
    }

    return result;
  }

  QVariantMap ExplorerController::describeMenu(const explorer::Around& around) const {
    const auto machine = machineOf(view_.current);
    const auto look = explorer::menu(view_, cacheOf(machine), explorer::contextOf(around, machine));
    QVariantList lines;

    for (std::size_t index = 0; index < look.count; ++index) {
      const auto& line = look.lines[index];

      lines.push_back(QVariantMap{
          {QStringLiteral("label"), fixedText(line.label)},
          {QStringLiteral("keys"), fixedText(line.keys)},
          {QStringLiteral("enabled"), line.enabled},
          {QStringLiteral("rule"), line.rule},
          {QStringLiteral("current"), line.current},
      });
    }

    if (lines.isEmpty()) {
      return {};
    }

    const auto& window = *view_.windows[view_.current];

    return {
        {QStringLiteral("lines"), lines},
        {QStringLiteral("window"), static_cast<int>(view_.current)},
        {QStringLiteral("row"), static_cast<int>(window.cursor) - static_cast<int>(window.top)},
        {QStringLiteral("x"), menu_at_.x()},
        {QStringLiteral("y"), menu_at_.y()},
    };
  }

  QVariantList ExplorerController::describePlan(const explorer::Around& around) const {
    QVariantList result;
    const auto here = machineOf(view_.current);
    const auto root = view_.windows.empty() ? std::string_view{} : view_.windows[view_.current]->root.view();
    // A plan for more than one machine says the machine of each line.
    const bool several = std::ranges::any_of(view_.plan, [&](const explorer::PlanStep& step) {
      return step.machine != view_.plan[0].machine || step.source_machine != 0;
    });

    for (const auto& step : view_.plan) {
      const auto context = explorer::contextOf(around, step.machine);
      const auto home = context.home;
      // A path below the root of the window that has the keys reads from there, when it is of
      // its machine; another one from the home, or whole.
      const auto shown = [&](std::string_view path) {
        if (step.machine == here && root.size() > 1 && path.starts_with(root) && path.size() > root.size() && path[root.size()] == '/') {
          return toQString(path.substr(root.size() + 1));
        }

        return home.size() > 1 && path.starts_with(home) && path.size() > home.size() && path[home.size()] == '/' ? QStringLiteral("~") + toQString(path.substr(home.size())) : toQString(path);
      };

      const auto note = explorer::planNote(view_, cacheOf(step.machine), step, {.touched = explorer::touchedSince(cacheOf(step.source_machine != 0 ? step.source_machine : step.machine), step), .edited = around.edited, .machine = context.machine, .source = step.source_machine != 0 ? explorer::contextOf(around, step.source_machine).machine : std::string_view{}});

      result.push_back(QVariantMap{
          {QStringLiteral("verb"), toQString(explorer::verbText(step.verb))},
          // What comes from another machine says which, as scp writes it.
          {QStringLiteral("source"), step.source_machine != 0 ? toQString(explorer::contextOf(around, step.source_machine).machine) + QLatin1Char(':') + toQString(step.source.view()) : shown(step.source.view())},
          {QStringLiteral("target"), shown(step.target.view())},
          {QStringLiteral("directory"), step.directory},
          {QStringLiteral("machine"), several ? toQString(context.machine) : QString{}},
          {QStringLiteral("size"), fixedText(note.size)},
          {QStringLiteral("warning"), fixedText(note.warning)},
          {QStringLiteral("note"), fixedText(note.note)},
      });
    }

    return result;
  }

  QVariantList ExplorerController::help() const {
    return helpGroups(explorer::help(view_));
  }

  const QVariantList& ExplorerController::windows() const noexcept {
    return windows_;
  }

  const QVariantList& ExplorerController::lenses() const noexcept {
    return lenses_;
  }

  const QVariantMap& ExplorerController::line() const noexcept {
    return line_;
  }

  const QVariantList& ExplorerController::hints() const noexcept {
    return hints_;
  }

  const QVariantMap& ExplorerController::preview() const noexcept {
    return preview_;
  }

  const QVariantList& ExplorerController::plan() const noexcept {
    return plan_;
  }

  const QVariantMap& ExplorerController::menu() const noexcept {
    return menu_;
  }

  const QVariantList& ExplorerController::transfers() const noexcept {
    return transfers_;
  }

  QVariantMap ExplorerController::record(const explorer::State& cache, const explorer::Context& context, explorer::Pick pick) const {
    const auto look = explorer::look(view_, cache, context, pick);
    const bool entry = look.kind == RowKind::entry || look.kind == RowKind::added || look.kind == RowKind::change || look.kind == RowKind::match;
    QVariantMap result{
        {QStringLiteral("kind"), QString::fromLatin1(kind_names[static_cast<std::size_t>(look.kind)])},
        {QStringLiteral("index"), static_cast<int>(pick.row)},
        {QStringLiteral("depth"), static_cast<int>(look.depth)},
        {QStringLiteral("directory"), look.directory},
        {QStringLiteral("expanded"), look.expanded},
        {QStringLiteral("selected"), look.selected},
        {QStringLiteral("marked"), look.marked},
        {QStringLiteral("ignored"), look.ignored},
        {QStringLiteral("removed"), look.removed},
        {QStringLiteral("renamed"), look.renamed},
        {QStringLiteral("added"), look.added},
        {QStringLiteral("arriving"), look.arriving},
        {QStringLiteral("lead"), fixedText(look.lead)},
        {QStringLiteral("name"), fixedText(look.name)},
        {QStringLiteral("tone"), QString::fromLatin1(diff_tones[static_cast<std::size_t>(look.tone)])},
        {QStringLiteral("staged"), letter(look.unstaged == FileState::untracked ? look.unstaged : look.staged)},
        {QStringLiteral("unstaged"), letter(look.unstaged)},
        {QStringLiteral("below"), look.below},
        {QStringLiteral("linesAdded"), look.lines_added},
        {QStringLiteral("linesRemoved"), look.lines_removed},
        {QStringLiteral("size"), fixedText(look.size)},
        {QStringLiteral("share"), static_cast<double>(look.share) / whole_share},
        {QStringLiteral("measured"), look.measured},
        {QStringLiteral("partial"), look.partial},
        {QStringLiteral("marks"), fixedText(look.marks)},
        {QStringLiteral("panes"), numbers(look.panes.view().first(look.pane_count))},
        {QStringLiteral("note"), fixedText(look.note)},
        {QStringLiteral("actors"), actorChips(look.actors.view().first(look.actor_count))},
        {QStringLiteral("editor"), QString::fromLatin1(editor_holds[static_cast<std::size_t>(look.editor)])},
        {QStringLiteral("verb"), fixedText(look.verb)},
        {QStringLiteral("ago"), fixedText(look.ago)},
        {QStringLiteral("editing"), view_.mode == Mode::insert && pick.window == view_.current && look.selected},
    };

    if (entry) {
      putIcon(result, look.directory ? directoryIcon() : fileIcon(look.name.view()));
    }

    return result;
  }

  void ExplorerController::publish() {
    edited_ = scene_.edited_revision;
    const auto around = explorer::around(scene_);

    for (std::size_t index = 0; index < rows_.size(); ++index) {
      QList<QVariantMap> records;

      if (index < view_.windows.size()) {
        const auto& window = *view_.windows[index];
        const auto end = std::min(window.rows.size(), window.top + window.page);
        // The cache and the facts of the window's machine, found once for all its rows.
        const auto& cache = cacheOf(window.machine);
        const auto context = explorer::contextOf(around, window.machine);

        records.reserve(static_cast<qsizetype>(end - std::min(window.top, end)));
        for (auto row = window.top; row < end; ++row) {
          records.push_back(record(cache, context, {.window = index, .row = row}));
        }
      }

      rows_.atMut(index).replaceRows(std::move(records));
    }

    // A part that reads as it did is not told again, so nothing that draws it is built again.
    const auto tell = [this](auto& shown, auto described, void (ExplorerController::*told)()) {
      if (shown != described) {
        shown = std::move(described);
        emit(this->*told)();
      }
    };

    tell(windows_, describeWindows(around), &ExplorerController::windowsChanged);
    tell(lenses_, describeLenses(around), &ExplorerController::lensesChanged);
    tell(line_, describeLine(), &ExplorerController::lineChanged);
    tell(hints_, describeHints(around), &ExplorerController::hintsChanged);
    tell(preview_, describePreview(around), &ExplorerController::previewChanged);
    tell(plan_, describePlan(around), &ExplorerController::planChanged);
    tell(menu_, describeMenu(around), &ExplorerController::menuChanged);
    tell(transfers_, describeTransfers(around), &ExplorerController::transfersChanged);
  }

  bool ExplorerController::carry() {
    if (view_.transfers.empty()) {
      transfers_tick_.stop();
      settleOut();
      return false;
    }

    const auto around = explorer::around(scene_);
    const auto machines = store_.machines().rows().size();
    const auto now = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
    // A machine that went away answers no transfer.
    bool changed = explorer::strand(view_, explorer::contextOf(around, scene_.shown), now) != 0;

    // Twice: what one machine answered is what the other is asked next, whichever comes first.
    for (int pass = 0; pass < 2; ++pass) {
      for (std::size_t slot = 0; slot < machines; ++slot) {
        if (auto* session = keepsMachine(store_, slot) ? explorerSessionMut(store_, slot) : nullptr) {
          changed = explorer::carry(*session, view_, explorer::contextOf(around, explorerMachine(slot)), now) || changed;
        }
      }
    }

    // While one is on its way its rate is told again, and one that ended leaves in a while.
    if (view_.transfers.empty()) {
      transfers_tick_.stop();
    } else if (!transfers_tick_.isActive()) {
      transfers_tick_.start();
    }

    settleOut();
    return changed;
  }

  void ExplorerController::cancelTransfer(int id) {
    if (id > 0 && explorer::stopTransfer(view_, static_cast<std::uint32_t>(id))) {
      synchronize();
    }
  }

  QVariantList ExplorerController::describeTransfers(const explorer::Around& around) const {
    QVariantList result;

    if (view_.transfers.empty()) {
      return result;
    }

    const auto now = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
    const auto looks = explorer::transfers(view_, explorer::contextOf(around, scene_.shown), now);

    for (std::size_t index = 0; index < looks.count; ++index) {
      const auto& look = looks.items[index];

      result.push_back(QVariantMap{
          {QStringLiteral("id"), look.id},
          {QStringLiteral("name"), fixedText(look.name)},
          {QStringLiteral("route"), fixedText(look.route)},
          {QStringLiteral("progress"), fixedText(look.progress)},
          {QStringLiteral("share"), static_cast<double>(look.share) / whole_share},
          {QStringLiteral("rate"), fixedText(look.rate)},
          {QStringLiteral("phase"), toQString(look.phase)},
          {QStringLiteral("ended"), look.ended},
          {QStringLiteral("failed"), look.failed},
          {QStringLiteral("more"), index + 1 == looks.count ? static_cast<int>(looks.more) : 0},
      });
    }

    return result;
  }

  void ExplorerController::finish(const explorer::Action& action) {
    const auto around = explorer::around(scene_);
    const auto machines = store_.machines().rows().size();
    // What is asked of a runtime goes to the session of each machine, which takes its own part;
    // what goes to a pane, to the session that shows them.
    bool sent = true;

    for (std::size_t slot = 0; slot < machines; ++slot) {
      if (auto* session = keepsMachine(store_, slot) ? explorerSessionMut(store_, slot) : nullptr) {
        sent = explorer::send(*session, view_, explorer::contextOf(around, explorerMachine(slot)), action) && sent;
      }
    }

    finish(sent ? explorer::deliver(store_.sessionMut(), view_, explorer::contextOf(around, scene_.shown), action) : Effect::none);
    // Files opened in an editor of another machine, and a pane of it given the focus, show once
    // the window shows that machine.
    const bool shows = action.kind == explorer::ActionKind::open || action.kind == explorer::ActionKind::focus_pane;

    if (sent && shows && action.machine != scene_.shown && action.machine != 0 && keepsMachine(store_, static_cast<std::size_t>(action.machine - 1))) {
      emit machineRequested(store_.machines().token(static_cast<application::machines::Machines::Slot>(action.machine - 1)));
    }
  }

  void ExplorerController::finish(Effect effect) {
    if (effect == Effect::copy) {
      if (auto* clipboard = QGuiApplication::clipboard()) {
        clipboard->setText(toQString(view_.text.view()));
      }
    }

    // A window may have gone to another machine, whose cache builds it; each runtime is asked
    // for what its windows now lack.
    static_cast<void>(refresh());
    // What a plan sends between machines starts at once.
    static_cast<void>(carry());
    store_.touch();
    revision_ = view_.revision;
    publish();
    emit changed();
    if (effect == Effect::closed || !view_.open) {
      emit closed();
    }
  }

  bool ExplorerController::key(int key, const QString& text, int modifiers) {
    if (!view_.open) {
      return false;
    }

    // The keys a chord has no name for: F2 renames, as `cw` does, and the menu key or Shift+F10
    // asks for the menu of the selected row.
    if (key == Qt::Key_F2) {
      type(QStringLiteral("cw"));
      return true;
    }

    if (key == Qt::Key_Menu || (key == Qt::Key_F10 && Qt::KeyboardModifiers::fromInt(static_cast<Qt::KeyboardModifiers::Int>(modifiers)).testFlag(Qt::ShiftModifier))) {
      openMenu(static_cast<int>(view_.current), view_.windows.empty() ? -1 : static_cast<int>(view_.windows[view_.current]->cursor), QPointF{-1, -1});
      return true;
    }

    return strike(key, text, modifiers);
  }

  bool ExplorerController::strike(int key, const QString& text, int modifiers) {
    const QKeyEvent event{QEvent::KeyPress, key, Qt::KeyboardModifiers::fromInt(static_cast<Qt::KeyboardModifiers::Int>(modifiers)), text};
    const auto chord = NativeKeyAdapter::chord(event);
    if (chord.key == KeyChord::Key::character && chord.character == std::numeric_limits<std::uint32_t>::max()) {
      return false;
    }

    try {
      observe();

      const auto around = explorer::around(scene_);
      const auto machine = machineOf(view_.current);

      finish(explorer::press(view_, explorerCacheMut(store_, away_, machine), explorer::contextOf(around, machine), chord));
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }

    return true;
  }

  void ExplorerController::typed(const QString& text) {
    const auto bytes = text.toUtf8();

    observe();

    const auto around = explorer::around(scene_);
    const auto machine = machineOf(view_.current);

    explorer::typed(view_, cacheOf(machine), explorer::contextOf(around, machine), {bytes.constData(), static_cast<std::size_t>(bytes.size())});
    finish(Effect::none);
  }

  void ExplorerController::submit(const QString& text) {
    const auto bytes = text.toUtf8();

    try {
      observe();

      const auto around = explorer::around(scene_);
      const auto machine = machineOf(view_.current);

      finish(explorer::submit(view_, explorerCacheMut(store_, away_, machine), explorer::contextOf(around, machine), {bytes.constData(), static_cast<std::size_t>(bytes.size())}));
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }
  }

  void ExplorerController::cancel() {
    observe();

    const auto around = explorer::around(scene_);
    const auto machine = machineOf(view_.current);

    explorer::cancel(view_, cacheOf(machine), explorer::contextOf(around, machine));
    finish(Effect::none);
  }

  void ExplorerController::complete(const QString& text) {
    const auto bytes = text.toUtf8();

    observe();

    const auto around = explorer::around(scene_);
    const std::string_view line{bytes.constData(), static_cast<std::size_t>(bytes.size())};
    // A path of another machine is completed by what that machine lists.
    const auto machine = explorer::completedOn(view_, explorer::contextOf(around, machineOf(view_.current)), line);

    explorer::complete(view_, cacheOf(machine), explorer::contextOf(around, machine), line);
    finish(Effect::none);
  }

  void ExplorerController::select(int window, int row, bool extend, bool toggle) {
    if (window < 0 || row < 0) {
      return;
    }

    observe();

    const auto around = explorer::around(scene_);
    const auto machine = machineOf(static_cast<std::size_t>(window));

    explorer::click(view_, cacheOf(machine), explorer::contextOf(around, machine), {.window = static_cast<std::size_t>(window), .row = static_cast<std::size_t>(row), .extend = extend, .toggle = toggle});
    finish(Effect::none);
  }

  void ExplorerController::climb(int window, const QString& directory) {
    if (window < 0 || static_cast<std::size_t>(window) >= view_.windows.size()) {
      return;
    }

    const auto bytes = directory.toUtf8();

    observe();

    const auto around = explorer::around(scene_);
    const auto machine = machineOf(static_cast<std::size_t>(window));

    explorer::climb(view_, cacheOf(machine), explorer::contextOf(around, machine), {.window = static_cast<std::size_t>(window), .directory = {bytes.constData(), static_cast<std::size_t>(bytes.size())}});
    finish(Effect::none);
  }

  void ExplorerController::step(int rows) {
    observe();

    const auto around = explorer::around(scene_);
    const auto machine = machineOf(view_.current);

    explorer::step(view_, cacheOf(machine), explorer::contextOf(around, machine), rows);
    finish(Effect::none);
  }

  void ExplorerController::openMenu(int window, int row, const QPointF& place) {
    if (window < 0 || !view_.open) {
      return;
    }

    menu_at_ = place;
    observe();

    const auto around = explorer::around(scene_);
    const auto machine = machineOf(static_cast<std::size_t>(window));

    explorer::openMenu(view_, cacheOf(machine), explorer::contextOf(around, machine), pickOf(window, row));
    finish(Effect::none);
  }

  void ExplorerController::chooseMenu(int line) {
    if (line < 0) {
      return;
    }

    try {
      observe();

      const auto around = explorer::around(scene_);
      const auto machine = machineOf(view_.current);

      finish(explorer::chooseMenu(view_, explorerCacheMut(store_, away_, machine), explorer::contextOf(around, machine), static_cast<std::size_t>(line)));
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }
  }

  bool ExplorerController::isChosen(int window, int row) const {
    if (window < 0 || row < 0 || std::cmp_greater_equal(window, view_.windows.size())) {
      return false;
    }

    return std::cmp_equal(window, view_.current) && explorer::chosen(view_, *view_.windows[static_cast<std::size_t>(window)], static_cast<std::size_t>(row));
  }

  int ExplorerController::grab(int window, int row) {
    if (window < 0 || row < 0 || !view_.open) {
      return 0;
    }

    observe();

    const auto around = explorer::around(scene_);
    const auto machine = machineOf(static_cast<std::size_t>(window));
    const auto carried = explorer::grab(view_, cacheOf(machine), explorer::contextOf(around, machine), pickOf(window, row));

    finish(Effect::none);
    return static_cast<int>(carried);
  }

  int ExplorerController::grabFiles(const QList<QUrl>& urls) {
    if (!view_.open || urls.isEmpty()) {
      return 0;
    }

    QList<QByteArray> local;
    // As many paths as a drag most often brings stay on the stack.
    constexpr qsizetype usual_paths = 16;
    QVarLengthArray<std::string_view, usual_paths> paths;

    for (const auto& url : urls) {
      if (!url.isLocalFile()) {
        // A link to a page or a file of somewhere else names nothing the runtime can copy.
        explorer::say(view_, "Only files of this machine are dropped here", explorer::Tone::error);
        finish(Effect::none);
        return 0;
      }

      local.push_back(url.toLocalFile().toUtf8());
    }

    for (const auto& path : local) {
      paths.push_back(std::string_view{path.constData(), static_cast<std::size_t>(path.size())});
    }

    observe();

    const auto around = explorer::around(scene_);
    const auto held = explorer::bringIn(view_, explorer::contextOf(around, scene_.shown), std::span<const std::string_view>{paths});

    finish(Effect::none);
    return static_cast<int>(held);
  }

  QVariantMap ExplorerController::aim(int window, int row, bool copy, bool move) const {
    if (window < 0 || !view_.open) {
      return {};
    }

    const auto pick = pickOf(window, row);
    const auto around = explorer::around(scene_);
    const auto machine = machineOf(pick.window);
    const auto aimed = explorer::aim(view_, cacheOf(machine), explorer::contextOf(around, machine), {.window = pick.window, .row = pick.row, .copy = copy, .move = move});

    return {{QStringLiteral("count"), static_cast<int>(aimed.count)}, {QStringLiteral("row"), aimed.row ? static_cast<int>(*aimed.row) : -1}, {QStringLiteral("copy"), aimed.copy}};
  }

  void ExplorerController::drop(int window, int row, bool copy, bool move) {
    if (window < 0 || !view_.open) {
      release();
      return;
    }

    const auto pick = pickOf(window, row);

    observe();

    const auto around = explorer::around(scene_);
    const auto machine = machineOf(pick.window);

    explorer::drop(view_, cacheOf(machine), explorer::contextOf(around, machine), {.window = pick.window, .row = pick.row, .copy = copy, .move = move});
    finish(Effect::none);
  }

  namespace {

    // What a row is to a program that reads text: its path, after its machine when that is
    // another, as scp and rsync read it and as `yy` writes it.
    QString lineOf(const explorer::Context& context, std::string_view path) {
      const auto text = toQString(path);

      return context.local ? text : toQString(context.machine) + QLatin1Char{':'} + text;
    }

    std::string_view bytesOf(const QByteArray& text) {
      return {text.constData(), static_cast<std::size_t>(text.size())};
    }

  }

  std::unique_ptr<QMimeData> ExplorerController::draggedData() {
    observe();

    const auto around = explorer::around(scene_);
    const bool held = !view_.dragged.empty();
    auto data = std::make_unique<QMimeData>();
    QStringList lines;
    // Of the rows that left, the files that were carried here for them.
    QList<QUrl> urls = held ? QList<QUrl>{} : fetched_;

    for (const auto& item : held ? view_.dragged.view() : view_.left.view()) {
      const auto context = explorer::contextOf(around, item.machine);

      lines.push_back(lineOf(context, item.path.view()));
      if (context.local) {
        urls.push_back(QUrl::fromLocalFile(toQString(item.path.view())));
      }
    }

    if (!lines.isEmpty()) {
      data->setText(lines.join(QLatin1Char{'\n'}));
    }

    if (!urls.isEmpty()) {
      data->setUrls(urls);
    }

    return data;
  }

  void ExplorerController::carryOutAs(explorer::Outside outside, const QString& cache) {
    outside_ = outside;
    drag_cache_ = cache;
  }

  void ExplorerController::dragOut(QQuickWindow* window) {
    observe();
    abandonOut();
    fetched_.clear();
    if (explorer::takeOut(view_) == 0) {
      return;
    }

    const auto around = explorer::around(scene_);
    const auto here = explorer::contextOf(around, scene_.shown);
    QStringList lines;
    // As many rows as a drag most often carries stay on the stack.
    constexpr qsizetype usual_rows = 8;
    QVarLengthArray<std::size_t, usual_rows> cached;
    bool promised = false;

    for (std::size_t index = 0; index < view_.left.size(); ++index) {
      const auto& item = view_.left[index];

      lines.push_back(lineOf(explorer::contextOf(around, item.machine), item.path.view()));
      switch (explorer::leaves(view_, here, index, outside_)) {
      case explorer::Leaves::promised:
        promised = true;
        break;
      case explorer::Leaves::cached:
        cached.push_back(index);
        break;
      case explorer::Leaves::file:
      case explorer::Leaves::named:
        break;
      }
    }

    if (promised && window != nullptr) {
      promiseOut(*window, lines);
    } else if (!cached.isEmpty() && fetchFirst(std::span<const std::size_t>{cached})) {
      // The system has the rows once their files are here; until then they can be let go.
      leaving_ = true;
      synchronize();
    } else {
      beginDrag();
    }
  }

  void ExplorerController::promiseOut(QQuickWindow& window, const QStringList& lines) {
    const auto around = explorer::around(scene_);
    const auto here = explorer::contextOf(around, scene_.shown);
    const auto count = view_.left.size();
    constexpr qsizetype usual_rows = 8;
    QVarLengthArray<QByteArray, usual_rows> texts;
    QVarLengthArray<platform::DraggedOut, usual_rows> rows;

    // The rows read the lines where they are kept, once all of them are.
    for (const auto& line : lines) {
      texts.push_back(line.toUtf8());
    }

    for (std::size_t index = 0; index < count && std::cmp_less(index, texts.size()); ++index) {
      const auto& item = view_.left[index];
      const auto kind = explorer::leaves(view_, here, index, outside_);

      rows.push_back({
          .text = bytesOf(texts.at(static_cast<qsizetype>(index))),
          .path = kind == explorer::Leaves::file ? item.path.view() : std::string_view{},
          .promised = kind == explorer::Leaves::promised ? explorer::baseOf(item.path.view()) : std::string_view{},
          .row = static_cast<std::uint32_t>(index),
          .directory = item.directory,
      });
    }

    // The system asks after the drag ended, and for as long as the rows are kept: no longer than
    // this controller is.
    static_cast<void>(drag_.give(window, std::span<const platform::DraggedOut>{rows}, [this](const platform::PromisedFile& file) {
      fetchPromised(file);
    }));
  }

  void ExplorerController::fetchPromised(const platform::PromisedFile& file) {
    observe();

    const auto around = explorer::around(scene_);
    const auto transfer = explorer::fetch(view_, explorer::contextOf(around, scene_.shown), {.index = file.row, .directory = file.directory, .name = file.name});

    if (transfer == 0) {
      drag_.end(file.ticket, "telar carries no file there");
      return;
    }

    promised_.push({.transfer = transfer, .ticket = file.ticket, .path = toQString(file.directory) + QLatin1Char{'/'} + toQString(file.name)});
    synchronize();
  }

  bool ExplorerController::fetchFirst(std::span<const std::size_t> rows) {
    const auto root = drag_cache_.toUtf8();
    QByteArray directory;

    {
      ds::String<Memory> made{view_.memory};

      if (!openDragCache(made, bytesOf(root), scene_.now)) {
        return false;
      }

      directory = QByteArray{made.view().data(), static_cast<qsizetype>(made.view().size())};
    }

    for (const auto row : rows) {
      if (row >= view_.left.size()) {
        continue;
      }

      // Under its own name, which is read before the transfer is added to what the view holds.
      const auto path = QString::fromUtf8(directory) + QLatin1Char{'/'} + toQString(explorer::baseOf(view_.left[row].path.view()));
      const auto around = explorer::around(scene_);
      const auto transfer = explorer::fetch(view_, explorer::contextOf(around, scene_.shown), {.index = row, .directory = bytesOf(directory), .name = {}});

      if (transfer != 0) {
        waited_.push({.transfer = transfer, .ticket = 0, .path = path});
      }
    }

    return !waited_.empty();
  }

  void ExplorerController::settleOut() {
    for (std::size_t index = promised_.size(); index-- > 0;) {
      const auto transfer = promised_[index].transfer;
      const auto state = explorer::fetching(view_, transfer);

      if (state == explorer::Fetching::carried) {
        continue;
      }

      const auto said = explorer::saidOf(view_, transfer);
      const QByteArray why{said.data(), static_cast<qsizetype>(said.size())};
      // A name that was taken leaves what arrived beside it, under another: not where the
      // system was told it would be.
      const bool elsewhere = state == explorer::Fetching::arrived && toQString(explorer::placedOf(view_, transfer)) != promised_[index].path;
      const auto ticket = promised_.remove(index).ticket;

      // The system is told last: what it does then may ask for another file.
      if (elsewhere) {
        drag_.end(ticket, "its name was taken there, and it arrived under another beside it");
      } else if (state == explorer::Fetching::arrived) {
        drag_.end(ticket, {});
      } else {
        drag_.end(ticket, why.isEmpty() ? std::string_view{"it did not arrive"} : bytesOf(why));
      }
    }

    const bool waiting = std::ranges::any_of(waited_, [&](const Awaited& awaited) {
      return explorer::fetching(view_, awaited.transfer) == explorer::Fetching::carried;
    });

    if (!leaving_ || waiting) {
      return;
    }

    // One that did not arrive is still named by its line of text; one that did is where its
    // transfer put it.
    for (const auto& awaited : waited_) {
      if (explorer::fetching(view_, awaited.transfer) == explorer::Fetching::arrived) {
        fetched_.push_back(QUrl::fromLocalFile(toQString(explorer::placedOf(view_, awaited.transfer))));
      }
    }

    waited_.clear();
    leaving_ = false;
    beginDrag();
  }

  void ExplorerController::abandonOut() {
    if (!leaving_) {
      return;
    }

    // What is still on its way is stopped, and what had arrived of it is removed.
    for (const auto& awaited : waited_) {
      static_cast<void>(explorer::stopTransfer(view_, awaited.transfer));
    }

    waited_.clear();
    leaving_ = false;
  }

  void ExplorerController::beginDrag() {
    auto data = draggedData();

    if (!data->hasText()) {
      return;
    }

    // Qt owns the drag from here and deletes it when it ends. It starts once the handler that
    // asked for it returned, since it runs its own loop until the rows are let go.
    auto* drag = new QDrag{this}; // NOLINT(cppcoreguidelines-owning-memory): its parent, this controller, owns it until Qt deletes it when the drag ends.

    drag->setMimeData(data.release());
    QTimer::singleShot(0, drag, [drag] {
      drag->exec(Qt::CopyAction);
    });
  }

  void ExplorerController::release() {
    explorer::release(view_);
    if (leaving_) {
      abandonOut();
      synchronize();
    }
  }

  void ExplorerController::dropOnPane(qulonglong pane) {
    if (!view_.open) {
      release();
      return;
    }

    observe();

    const auto around = explorer::around(scene_);
    const auto machine = machineOf(view_.current);

    finish(explorer::hand(view_, cacheOf(machine), explorer::contextOf(around, machine), static_cast<std::uint64_t>(pane)));
  }

  void ExplorerController::activate(int window, int row) {
    if (window < 0 || row < 0) {
      return;
    }

    try {
      observe();

      const auto around = explorer::around(scene_);
      const auto machine = machineOf(static_cast<std::size_t>(window));

      finish(explorer::activate(view_, explorerCacheMut(store_, away_, machine), explorer::contextOf(around, machine), {.window = static_cast<std::size_t>(window), .row = static_cast<std::size_t>(row)}));
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }
  }

  void ExplorerController::toggleRow(int window, int row) {
    if (window < 0 || row < 0) {
      return;
    }

    observe();

    const auto around = explorer::around(scene_);
    const auto machine = machineOf(static_cast<std::size_t>(window));

    explorer::toggle(view_, cacheOf(machine), explorer::contextOf(around, machine), {.window = static_cast<std::size_t>(window), .row = static_cast<std::size_t>(row)});
    finish(Effect::none);
  }

  void ExplorerController::setViewport(int window, int rows) {
    // More rows than any screen shows.
    constexpr int most_rows = 1000;

    if (window < 0 || static_cast<std::size_t>(window) >= view_.windows.size() || std::cmp_equal(rows, view_.windows[static_cast<std::size_t>(window)]->page)) {
      return;
    }

    explorer::resize(view_, {.window = static_cast<std::size_t>(window), .count = std::clamp(rows, 1, most_rows)});
    publish();
    emit changed();
  }

  void ExplorerController::scroll(int window, int rows) {
    if (window < 0) {
      return;
    }

    explorer::scroll(view_, {.window = static_cast<std::size_t>(window), .count = rows});
    publish();
    emit changed();
  }

  void ExplorerController::type(const QString& keys) {
    for (qsizetype index = 0; index < keys.size();) {
      const auto close = keys[index] == QLatin1Char('<') ? keys.indexOf(QLatin1Char('>'), index) : -1;
      if (close > index) {
        if (const auto* known = namedKey(QStringView{keys}.mid(index, close - index + 1))) {
          strike(known->key, QString{known->text}, known->modifiers);
        }

        index = close + 1;
        continue;
      }

      const auto character = keys[index];

      strike(character.toUpper().unicode(), QString{character}, character.isUpper() ? static_cast<int>(Qt::ShiftModifier) : 0);
      ++index;
    }
  }

  void ExplorerController::run(const QString& command) {
    type(QStringLiteral(":"));
    submit(command);
  }

  void ExplorerController::close() {
    // As a pane it closes with its pane, as `:q` closes it.
    if (view_.host != 0) {
      finish(explorer::Action{.kind = explorer::ActionKind::close});
      return;
    }

    explorer::close(view_);
    finish(Effect::closed);
  }

  void ExplorerController::toggle() {
    // As a pane the key gives its pane the focus, or returns it to the pane it came from; `q`
    // closes it.
    if (const auto pane = explorer::standing(store_.session())) {
      const auto* focused = store_.session().focusedPane();

      if (focused == nullptr || focused->id != pane) {
        application::workbench::focusPane(store_.sessionMut(), pane);
      } else {
        // With the focus in its pane, the scene says the pane it stands in for.
        observe();
        if (scene_.focused != 0) {
          application::workbench::focusPane(store_.sessionMut(), scene_.focused);
        }
      }

      store_.touch();
      return;
    }

    if (view_.open) {
      close();
      return;
    }

    if (!explorer::available(store_.session())) {
      emit failed(QStringLiteral("This machine's runtime does not answer the explorer; update telar there"));
      return;
    }

    observe();
    {
      const auto around = explorer::around(scene_);

      explorer::open(view_, cacheOf(scene_.shown), explorer::contextOf(around, scene_.shown), scene_.shown);
    }

    present(true);
  }

  void ExplorerController::present(bool opening) {
    static_cast<void>(refresh());
    revision_ = view_.revision;
    publish();
    emit changed();
    if (opening) {
      emit opened();
    }
  }

  void ExplorerController::reveal(std::string_view path, std::string_view directory) {
    if (!explorer::available(store_.session())) {
      emit failed(QStringLiteral("This machine's runtime does not answer the explorer; update telar there"));
      return;
    }

    const bool opening = !view_.open;
    bool revealed = false;

    observe();
    {
      const auto around = explorer::around(scene_);

      revealed = explorer::reveal(view_, cacheOf(scene_.shown), explorer::contextOf(around, scene_.shown), {.path = path, .directory = directory});
    }

    if (!revealed) {
      emit failed(QStringLiteral("The explorer waits for an answer: it stays where it is"));
      return;
    }

    // As a pane it takes the focus: the person asked for it.
    if (view_.host != 0) {
      application::workbench::focusPane(store_.sessionMut(), view_.host);
      store_.touch();
    }

    present(opening);
  }

  bool ExplorerController::settle() {
    bool closed = false;

    // The window shows another machine: the pane it stood as is of the session that showed,
    // which keeps what it was last given.
    if (view_.host != 0 && store_.machines().active() != shown_) {
      view_.host = 0;
      explorer::pin(view_, false);
      explorer::close(view_);
      closed = true;
    }

    // Nothing to look at, and nothing read of the panes, while the explorer stands as no pane
    // and the tab that shows has none that is one.
    if (view_.host != 0 || explorer::standing(store_.session()) != 0) {
      observe();

      const auto around = explorer::around(scene_);

      closed = explorer::host(store_.sessionMut(), view_, explorer::contextOf(around, scene_.shown)) == explorer::Stood::left || closed;
    }

    if (!closed || view_.open) {
      return false;
    }

    revision_ = view_.revision;
    publish();
    emit changed();
    emit this->closed();
    return true;
  }

  void ExplorerController::synchronize() {
    // The tab that shows may have the explorer as a pane, or no longer have the one it stood as.
    if (settle()) {
      return;
    }

    // A file on its way between two machines goes on while the explorer is closed.
    if (!view_.open && view_.transfers.empty()) {
      return;
    }

    observe();

    const bool carried = carry();

    if (!view_.open) {
      // The sidebar lists them while the explorer is closed.
      if (carried) {
        if (auto described = describeTransfers(explorer::around(scene_)); described != transfers_) {
          transfers_ = std::move(described);
          emit transfersChanged();
        }

        store_.touch();
      }

      return;
    }

    // The files the editors hold are no change of the view: its rows mark them all the same.
    if (refresh() || carried || revision_ != view_.revision || edited_ != scene_.edited_revision) {
      revision_ = view_.revision;
      publish();
      emit changed();
    }
  }

  void ExplorerController::machineChanged() {
    if (!view_.open) {
      return;
    }

    // The panes of another machine are other panes: the explorer opens again over them. A
    // machine that was renamed, or came or went, only shows so.
    if (store_.machines().active() != shown_) {
      // The pane it stood as is of the session that showed, which keeps what it was last given.
      view_.host = 0;
      explorer::pin(view_, false);
      close();
      return;
    }

    // A label reads from the machines, which no cache says changed: the heads are told again.
    observe();
    static_cast<void>(refresh());
    revision_ = view_.revision;
    publish();
    emit changed();
  }

  void ExplorerController::nextMachine(int window) {
    if (window < 0 || std::cmp_greater_equal(window, view_.windows.size())) {
      return;
    }

    select(window, static_cast<int>(view_.windows[static_cast<std::size_t>(window)]->cursor), false, false);
    type(QStringLiteral("gm"));
  }

  void ExplorerController::toggleFollow(int window) {
    if (window < 0 || std::cmp_greater_equal(window, view_.windows.size())) {
      return;
    }

    select(window, static_cast<int>(view_.windows[static_cast<std::size_t>(window)]->cursor), false, false);
    run(QStringLiteral("follow"));
  }

}

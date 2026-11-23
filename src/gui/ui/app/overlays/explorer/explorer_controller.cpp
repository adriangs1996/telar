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
#include <QGuiApplication>
#include <QKeyEvent>
#include <QVariantList>
#include <algorithm>
#include <exception>
#include <string_view>

import telar.gui.application;
import telar.gui.foundation.icons;

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
    constexpr ds::Array<const char*, 8> mode_names{"normal", "visual", "insert", "search", "command", "plan", "help", "menu"};
    constexpr ds::Array<const char*, 3> tone_names{"info", "error", "ask"};
    constexpr ds::Array<const char*, 3> follow_scopes{"pane", "workspace", "machine"};
    // The lines of a preview's text the window draws.
    constexpr qsizetype preview_lines = 200;
    constexpr double whole_share = 1000;

    template <std::size_t Capacity>
    QString fixedText(const runtime::FixedText<Capacity>& value) {
      return toQString(value.view());
    }

    // The letter git's short status gives a state, as the pickers write it.
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
        return QStringLiteral("U");
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

    // A line of the help: the keys, what they do, and the group it is listed under.
    struct HelpKey {
      std::string_view group;
      std::string_view keys;
      std::string_view label;
    };

    constexpr ds::Array<HelpKey, 51> help_keys{
        {
            {.group = "Moving", .keys = "j k", .label = "down, up; with a count"},
            {.group = "Moving", .keys = "gg G", .label = "first, last; 12G goes to row 12"},
            {.group = "Moving", .keys = "<C-d> <C-u>", .label = "half a page"},
            {.group = "Moving", .keys = "h l", .label = "fold, unfold; l on a file opens it"},
            {.group = "Moving", .keys = "za zM zR", .label = "toggle a fold, fold all, unfold a level"},
            {.group = "Moving", .keys = "]c [c", .label = "next, previous change of git"},
            {.group = "Roots and jumps", .keys = "<CR>", .label = "enter a directory"},
            {.group = "Roots and jumps", .keys = "-", .label = "the directory above"},
            {.group = "Roots and jumps", .keys = "_ ~", .label = "the workspace's root, the home"},
            {.group = "Roots and jumps", .keys = "gp gw gh", .label = "follow pane, workspace, machine"},
            {.group = "Roots and jumps", .keys = "ma 'a", .label = "set a mark, jump to it"},
            {.group = "Roots and jumps", .keys = "<C-o> <C-i>", .label = "back, forward in the jumps"},
            {.group = "Roots and jumps", .keys = "gt gT", .label = "next, previous lens"},
            {.group = "Editing as text", .keys = "cw i a", .label = "rename on the row"},
            {.group = "Editing as text", .keys = "o", .label = "new entry; name/ is a directory"},
            {.group = "Editing as text", .keys = "dd", .label = "cut: deletes, or with p moves"},
            {.group = "Editing as text", .keys = "yy", .label = "copy, and its path to the clipboard"},
            {.group = "Editing as text", .keys = "p", .label = "paste into the row's directory"},
            {.group = "Editing as text", .keys = "u", .label = "undo a change, else the last :w"},
            {.group = "Editing as text", .keys = ":w :w!", .label = "show the plan; overwrite what exists"},
            {.group = "Editing as text", .keys = ":e! :q!", .label = "discard the changes"},
            {.group = "Windows", .keys = "<C-w>v <C-w>s", .label = "another window beside, below"},
            {.group = "Windows", .keys = "<C-w>w <C-w>hjkl", .label = "the next window, the one that way"},
            {.group = "Windows", .keys = "<C-w>q <C-w>o", .label = "close this one, keep only this one"},
            {.group = "Windows", .keys = ":e PATH :vs PATH", .label = "this window, or a new one, at a path"},
            {.group = "Toward the panes", .keys = "<CR>", .label = "as the focused pane takes it"},
            {.group = "Toward the panes", .keys = "V <CR>", .label = "insert several, directories too"},
            {.group = "Toward the panes", .keys = "gf", .label = "open in the tab's editor"},
            {.group = "Toward the panes", .keys = "cd s", .label = "cd the shell here, a new shell here"},
            {.group = "Toward the panes", .keys = "@", .label = "mention to the agent"},
            {.group = "Toward the panes", .keys = "yr yn", .label = "copy the relative path, the name"},
            {.group = "Toward the panes", .keys = ".", .label = "repeat"},
            {.group = "Git, sizes and what shows", .keys = "=", .label = "the diff below the row"},
            {.group = "Git, sizes and what shows", .keys = "ga gu", .label = "stage, unstage"},
            {.group = "Git, sizes and what shows", .keys = "gX", .label = "discard changes, through the plan"},
            {.group = "Git, sizes and what shows", .keys = "gc", .label = ":commit with a message"},
            {.group = "Git, sizes and what shows", .keys = "S", .label = "sort by name, size, time"},
            {.group = "Git, sizes and what shows", .keys = "g. gi", .label = "dotfiles, what git ignores"},
            {.group = "Git, sizes and what shows", .keys = "R", .label = "read again"},
            {.group = "Modes", .keys = "V", .label = "visual: y d <CR> @ ga gu"},
            {.group = "Modes", .keys = "/ n N", .label = "filter every path below; next, previous"},
            {.group = "Modes", .keys = ":", .label = "e w vs sp cd commit marks q"},
            {.group = "Modes", .keys = "<Tab>", .label = "on a line of :, complete a directory"},
            {.group = "Modes", .keys = "F", .label = "follow the pane"},
            {.group = "Modes", .keys = "q", .label = "close"},
            {.group = "Modes", .keys = "?", .label = "this help"},
            {.group = "Pointer and shortcuts", .keys = "right click", .label = "the row's menu, with the key of each"},
            {.group = "Pointer and shortcuts", .keys = "Shift+F10", .label = "the menu, from the keys"},
            {.group = "Pointer and shortcuts", .keys = "drag", .label = "moves there on :w; Alt copies"},
            {.group = "Pointer and shortcuts", .keys = "<D-c> <D-x> <D-v>", .label = "copy, cut, paste; Control too"},
            {.group = "Pointer and shortcuts", .keys = "<D-z> <D-s> F2", .label = "undo, write, rename"},
        },
    };

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

    QVariantList helpGroups() {
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
      for (const auto& line : help_keys) {
        if (line.group != group) {
          close();
          group = line.group;
        }

        keys.push_back(QVariantMap{{QStringLiteral("keys"), toQString(line.keys)}, {QStringLiteral("label"), toQString(line.label)}});
      }

      close();
      return result;
    }

  }

  ExplorerController::ExplorerController(Store& store, ApplicationAllocator& memory, QObject* parent)
      : QObject(parent),
        store_(store),
        view_(memory),
        home_(QDir::homePath().toUtf8()) {
    // A model an invokable hands to QML with no parent would be the engine's to delete.
    for (auto& model : rows_.viewMut()) {
      model.setParent(this);
    }
  }

  explorer::Host ExplorerController::host() const {
    const auto& machines = store_.machines();
    const auto rows = machines.rows();
    const auto active = machines.active();
    const bool local = active == application::machines::Machines::local_slot;

    label_ = active < rows.size() ? QByteArray{rows[active].label.view().data(), static_cast<qsizetype>(rows[active].label.view().size())} : QByteArray{};
    return {
        .machine = static_cast<std::uint64_t>(active) + 1,
        .name = {label_.constData(), static_cast<std::size_t>(label_.size())},
        // The home of another machine's account is not known here.
        .home = local ? std::string_view{home_.constData(), static_cast<std::size_t>(home_.size())} : std::string_view{},
        .local = local,
    };
  }

  bool ExplorerController::available() const {
    return explorer::available(store_.session());
  }

  bool ExplorerController::showing() const {
    return view_.open;
  }

  bool ExplorerController::sideBySide() const {
    return view_.side_by_side;
  }

  QAbstractItemModel* ExplorerController::rows(int window) {
    return window >= 0 && static_cast<std::size_t>(window) < rows_.size() ? &rows_.atMut(static_cast<std::size_t>(window)) : nullptr;
  }

  QVariantList ExplorerController::describeWindows() const {
    const auto& session = store_.session();
    const auto machine = host();
    QVariantList result;

    for (std::size_t index = 0; index < view_.windows.size(); ++index) {
      const auto& window = *view_.windows[index];
      const auto header = explorer::header(session, view_, machine, index);
      const auto status = explorer::status(session, view_, machine, index);

      result.push_back(QVariantMap{
          {QStringLiteral("index"), static_cast<int>(index)},
          {QStringLiteral("current"), status.current},
          {QStringLiteral("machine"), fixedText(header.machine)},
          {QStringLiteral("local"), header.local},
          {QStringLiteral("lead"), fixedText(header.lead)},
          {QStringLiteral("last"), fixedText(header.last)},
          {QStringLiteral("repository"), header.repository},
          {QStringLiteral("branch"), fixedText(header.branch)},
          {QStringLiteral("upstream"), header.upstream},
          {QStringLiteral("ahead"), header.ahead},
          {QStringLiteral("behind"), header.behind},
          {QStringLiteral("staged"), header.staged},
          {QStringLiteral("unstaged"), header.unstaged},
          {QStringLiteral("untracked"), header.untracked},
          {QStringLiteral("mode"), toQString(status.mode)},
          {QStringLiteral("modeKind"), QString::fromLatin1(mode_names[static_cast<std::size_t>(status.kind)])},
          {QStringLiteral("following"), fixedText(status.following)},
          {QStringLiteral("follows"), status.follows},
          {QStringLiteral("root"), fixedText(status.root)},
          {QStringLiteral("pending"), status.pending},
          {QStringLiteral("flags"), fixedText(status.flags)},
          {QStringLiteral("filter"), fixedText(status.filter)},
          {QStringLiteral("total"), fixedText(status.total)},
          {QStringLiteral("keys"), fixedText(status.keys)},
          {QStringLiteral("chosen"), status.chosen},
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

  QVariantList ExplorerController::describeLenses() const {
    QVariantList result;

    if (view_.windows.empty()) {
      return result;
    }

    for (const auto& lens : explorer::lenses(store_.session(), view_, host())) {
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

  QVariantList ExplorerController::describeHints() const {
    QVariantList result;

    if (view_.windows.empty()) {
      return result;
    }

    const auto hints = explorer::hints(store_.session(), view_, host());

    for (std::size_t index = 0; index < hints.count; ++index) {
      const auto& hint = hints.items[index];

      result.push_back(QVariantMap{{QStringLiteral("keys"), toQString(hint.keys)}, {QStringLiteral("label"), fixedText(hint.label)}, {QStringLiteral("enabled"), hint.enabled}});
    }

    return result;
  }

  QVariantMap ExplorerController::describePreview() const {
    if (view_.windows.empty()) {
      return {};
    }

    const auto look = explorer::preview(store_.session(), view_, host(), static_cast<std::uint64_t>(QDateTime::currentSecsSinceEpoch()));
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
    auto rest = explorer::previewText(store_.session(), view_);

    while (!rest.empty() && lines.size() < preview_lines) {
      const auto end = rest.find('\n');
      const auto line = rest.substr(0, end);
      const auto tone = look.diff ? explorer::toneOf(line) : DiffTone::context;

      lines.push_back(QVariantMap{{QStringLiteral("text"), toQString(line)}, {QStringLiteral("tone"), QString::fromLatin1(diff_tones[static_cast<std::size_t>(tone)])}});
      rest.remove_prefix(end == std::string_view::npos ? rest.size() : end + 1);
    }

    QVariantMap result{
        {QStringLiteral("shown"), true},
        {QStringLiteral("directory"), look.directory},
        {QStringLiteral("name"), fixedText(look.name)},
        {QStringLiteral("path"), fixedText(look.path)},
        {QStringLiteral("facts"), facts},
        {QStringLiteral("panes"), numbers(look.panes.view().first(look.pane_count))},
        {QStringLiteral("title"), toQString(look.title)},
        {QStringLiteral("lines"), lines},
        {QStringLiteral("diff"), look.diff},
        {QStringLiteral("waiting"), look.waiting},
    };

    putIcon(result, look.directory ? directoryIcon() : fileIcon(look.name.view()));
    return result;
  }

  QVariantMap ExplorerController::describeMenu() const {
    const auto look = explorer::menu(store_.session(), view_, host());
    QVariantList lines;

    for (std::size_t index = 0; index < look.count; ++index) {
      const auto& line = look.lines[index];

      lines.push_back(QVariantMap{
          {QStringLiteral("label"), fixedText(line.label)},
          {QStringLiteral("keys"), toQString(line.keys)},
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

  QVariantList ExplorerController::describePlan() const {
    QVariantList result;
    const auto home = host().home;
    const auto root = view_.windows.empty() ? std::string_view{} : view_.windows[view_.current]->root.view();

    for (const auto& step : view_.plan) {
      // A path below the window's root reads from there; another one from the home, or whole.
      const auto shown = [&](std::string_view path) {
        if (root.size() > 1 && path.starts_with(root) && path.size() > root.size() && path[root.size()] == '/') {
          return toQString(path.substr(root.size() + 1));
        }

        return home.size() > 1 && path.starts_with(home) && path.size() > home.size() && path[home.size()] == '/' ? QStringLiteral("~") + toQString(path.substr(home.size())) : toQString(path);
      };

      result.push_back(QVariantMap{
          {QStringLiteral("verb"), toQString(explorer::verbText(step.verb))},
          {QStringLiteral("source"), shown(step.source.view())},
          {QStringLiteral("target"), shown(step.target.view())},
          {QStringLiteral("directory"), step.directory},
      });
    }

    return result;
  }

  QVariantList ExplorerController::help() {
    return helpGroups();
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

  QVariantMap ExplorerController::record(std::size_t window, std::size_t row) const {
    const auto look = explorer::look(store_.session(), view_, host(), {.window = window, .row = row});
    const bool entry = look.kind == RowKind::entry || look.kind == RowKind::added || look.kind == RowKind::change || look.kind == RowKind::match;
    QVariantMap result{
        {QStringLiteral("kind"), QString::fromLatin1(kind_names[static_cast<std::size_t>(look.kind)])},
        {QStringLiteral("index"), static_cast<int>(row)},
        {QStringLiteral("depth"), static_cast<int>(look.depth)},
        {QStringLiteral("directory"), look.directory},
        {QStringLiteral("expanded"), look.expanded},
        {QStringLiteral("selected"), look.selected},
        {QStringLiteral("marked"), look.marked},
        {QStringLiteral("ignored"), look.ignored},
        {QStringLiteral("removed"), look.removed},
        {QStringLiteral("renamed"), look.renamed},
        {QStringLiteral("added"), look.added},
        {QStringLiteral("lead"), fixedText(look.lead)},
        {QStringLiteral("name"), fixedText(look.name)},
        {QStringLiteral("tone"), QString::fromLatin1(diff_tones[static_cast<std::size_t>(look.tone)])},
        {QStringLiteral("staged"), letter(look.staged)},
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
        {QStringLiteral("editing"), view_.mode == Mode::insert && window == view_.current && look.selected},
    };

    if (entry) {
      putIcon(result, look.directory ? directoryIcon() : fileIcon(look.name.view()));
    }

    return result;
  }

  void ExplorerController::publish() {
    for (std::size_t index = 0; index < rows_.size(); ++index) {
      QList<QVariantMap> records;

      if (index < view_.windows.size()) {
        const auto& window = *view_.windows[index];
        const auto end = std::min(window.rows.size(), window.top + window.page);

        records.reserve(static_cast<qsizetype>(end - std::min(window.top, end)));
        for (auto row = window.top; row < end; ++row) {
          records.push_back(record(index, row));
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

    tell(windows_, describeWindows(), &ExplorerController::windowsChanged);
    tell(lenses_, describeLenses(), &ExplorerController::lensesChanged);
    tell(line_, describeLine(), &ExplorerController::lineChanged);
    tell(hints_, describeHints(), &ExplorerController::hintsChanged);
    tell(preview_, describePreview(), &ExplorerController::previewChanged);
    tell(plan_, describePlan(), &ExplorerController::planChanged);
    tell(menu_, describeMenu(), &ExplorerController::menuChanged);
  }

  void ExplorerController::finish(Effect effect) {
    if (effect == Effect::copy) {
      if (auto* clipboard = QGuiApplication::clipboard()) {
        clipboard->setText(toQString(view_.text.view()));
      }
    }

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
      finish(explorer::press(store_.sessionMut(), view_, host(), chord));
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }

    return true;
  }

  void ExplorerController::typed(const QString& text) {
    const auto bytes = text.toUtf8();

    explorer::typed(store_.sessionMut(), view_, host(), {bytes.constData(), static_cast<std::size_t>(bytes.size())});
    finish(Effect::none);
  }

  void ExplorerController::submit(const QString& text) {
    const auto bytes = text.toUtf8();

    try {
      finish(explorer::submit(store_.sessionMut(), view_, host(), {bytes.constData(), static_cast<std::size_t>(bytes.size())}));
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }
  }

  void ExplorerController::cancel() {
    explorer::cancel(store_.sessionMut(), view_, host());
    finish(Effect::none);
  }

  void ExplorerController::complete(const QString& text) {
    const auto bytes = text.toUtf8();

    explorer::complete(store_.sessionMut(), view_, host(), {bytes.constData(), static_cast<std::size_t>(bytes.size())});
    finish(Effect::none);
  }

  void ExplorerController::select(int window, int row, bool extend, bool toggle) {
    if (window < 0 || row < 0) {
      return;
    }

    explorer::select(store_.sessionMut(), view_, host(), {.window = static_cast<std::size_t>(window), .row = static_cast<std::size_t>(row), .extend = extend, .toggle = toggle});
    finish(Effect::none);
  }

  void ExplorerController::openMenu(int window, int row, const QPointF& place) {
    if (window < 0 || !view_.open) {
      return;
    }

    menu_at_ = place;
    explorer::openMenu(store_.sessionMut(), view_, host(), pickOf(window, row));
    finish(Effect::none);
  }

  void ExplorerController::chooseMenu(int line) {
    if (line < 0) {
      return;
    }

    try {
      finish(explorer::chooseMenu(store_.sessionMut(), view_, host(), static_cast<std::size_t>(line)));
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

    const auto carried = explorer::grab(store_.sessionMut(), view_, host(), pickOf(window, row));

    finish(Effect::none);
    return static_cast<int>(carried);
  }

  QVariantMap ExplorerController::aim(int window, int row, bool copy) const {
    if (window < 0 || !view_.open) {
      return {};
    }

    const auto pick = pickOf(window, row);
    const auto aimed = explorer::aim(store_.session(), view_, host(), {.window = pick.window, .row = pick.row, .copy = copy});

    return {{QStringLiteral("count"), static_cast<int>(aimed.count)}, {QStringLiteral("row"), aimed.row ? static_cast<int>(*aimed.row) : -1}};
  }

  void ExplorerController::drop(int window, int row, bool copy) {
    if (window < 0 || !view_.open) {
      release();
      return;
    }

    const auto pick = pickOf(window, row);

    explorer::drop(store_.sessionMut(), view_, host(), {.window = pick.window, .row = pick.row, .copy = copy});
    finish(Effect::none);
  }

  void ExplorerController::release() {
    explorer::release(view_);
  }

  void ExplorerController::activate(int window, int row) {
    if (window < 0 || row < 0) {
      return;
    }

    try {
      finish(explorer::activate(store_.sessionMut(), view_, host(), {.window = static_cast<std::size_t>(window), .row = static_cast<std::size_t>(row)}));
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }
  }

  void ExplorerController::toggleRow(int window, int row) {
    if (window < 0 || row < 0) {
      return;
    }

    explorer::toggle(store_.sessionMut(), view_, host(), {.window = static_cast<std::size_t>(window), .row = static_cast<std::size_t>(row)});
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
    explorer::close(view_);
    finish(Effect::closed);
  }

  void ExplorerController::toggle() {
    if (view_.open) {
      close();
      return;
    }

    if (!explorer::open(store_.sessionMut(), view_, host())) {
      emit failed(QStringLiteral("This machine's runtime does not answer the explorer; update telar there"));
      return;
    }

    revision_ = view_.revision;
    publish();
    emit changed();
    emit opened();
  }

  void ExplorerController::synchronize() {
    if (!view_.open) {
      return;
    }

    if (explorer::refresh(store_.sessionMut(), view_, host()) || revision_ != view_.revision) {
      revision_ = view_.revision;
      publish();
      emit changed();
    }
  }

  void ExplorerController::machineChanged() {
    if (view_.open) {
      close();
    }
  }

}

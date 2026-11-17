#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "palette_controller.hpp"
#include "ui/design/controls/form_text_grid.hpp"
#include "ui/foundation/models/projection.hpp"
#include "ui/foundation/text/utf16_encoding.hpp"
#include <QByteArray>
#include <QChar>
#include <QLatin1StringView>
#include <QStringView>
#include <QVariant>
#include <algorithm>
#include <span>
#include <utility>

import telar.gui.foundation.forms;
import telar.gui.application;

namespace telar::gui::qt {

  namespace {

    std::string_view paletteBytes(const QByteArray& text) {
      return {text.constData(), static_cast<std::size_t>(text.size())};
    }

    QString navigationKey(const NavigationTarget& target) {
      if (const auto* workspace = std::get_if<WorkspaceLocation>(&target)) {
        return QStringLiteral("context:") + QString::number(workspace->id);
      }

      if (const auto* tab = std::get_if<TabLocation>(&target)) {
        return QStringLiteral("tab:") + QString::number(static_cast<int>(tab->workspace.kind)) + QLatin1Char(':') + QString::number(tab->workspace.id) + QLatin1Char(':') + QString::number(tab->tab_id);
      }

      const auto agent = std::get<AgentNavigationTarget>(target);

      return QStringLiteral("agent:") + QString::number(agent.pane_id) + QLatin1Char(':') + QString::number(agent.pane_generation);
    }

    QString groupName(application::palette::PaletteRowKind kind) {
      switch (kind) {
      case application::palette::PaletteRowKind::context:
        return QStringLiteral("Contexts");
      case application::palette::PaletteRowKind::tab:
        return QStringLiteral("Tabs");
      case application::palette::PaletteRowKind::agent:
        return QStringLiteral("Agents");
      case application::palette::PaletteRowKind::action:
        return QStringLiteral("Actions");
      case application::palette::PaletteRowKind::machine:
        return QStringLiteral("Machines");
      default:
        return {};
      }
    }

    QVariantMap navigationRecord(const NavigationTarget& target, const application::palette::NavigationLabel& label, application::palette::PaletteRowKind kind, bool queried) {
      const auto text = label.view();
      const auto split = std::min(text.find(application::palette::NavigationLabel::detail_separator), text.size());
      auto primary = text.substr(0, split);
      auto secondary = text.substr(split);

      secondary.remove_prefix(std::min(secondary.find_first_not_of(' '), secondary.size()));
      if (kind == application::palette::PaletteRowKind::tab && primary.starts_with(application::palette::NavigationLabel::tab_prefix)) {
        primary.remove_prefix(application::palette::NavigationLabel::tab_prefix.size());
      }

      QString glyph = QStringLiteral("");

      if (kind == application::palette::PaletteRowKind::context) {
        glyph = QStringLiteral("");
      } else if (kind == application::palette::PaletteRowKind::tab) {
        glyph = QStringLiteral("");
      }

      const auto hint = kind == application::palette::PaletteRowKind::context ? QStringLiteral("context") : QStringLiteral("tab");

      return {
          {QStringLiteral("key"), navigationKey(target)},
          {QStringLiteral("kind"), static_cast<int>(kind)},
          {QStringLiteral("icon"), glyph},
          {QStringLiteral("primary"), toQString(primary)},
          {QStringLiteral("secondary"), toQString(secondary)},
          {QStringLiteral("hint"), queried ? hint : QString{}},
          {QStringLiteral("detailBelow"), false},
          {QStringLiteral("shortcut"), false},
      };
    }

  }

  PaletteController::PaletteController(Store& store, PaletteAction suggestion, QObject* parent)
      : QObject(parent),
        store_(store),
        suggestion_(suggestion) {}

  bool PaletteController::isOpen() const noexcept {
    return store_.dialog().kind == Store::Dialog::palette;
  }

  application::palette::PaletteMode PaletteController::mode() const {
    const auto text = query_.toUtf8();

    return application::palette::PaletteQuery::parse(paletteBytes(text)).mode;
  }

  const QString& PaletteController::query() const noexcept {
    return query_;
  }

  std::uint64_t PaletteController::rebuilds() const noexcept {
    return rebuilds_;
  }

  void PaletteController::setDisplay(const application::window::DisplayMetrics& display) {
    display_ = display;
    emit changed();
  }

  void PaletteController::setCommands(QVariantList commands) {
    commands_ = std::move(commands);
  }

  void PaletteController::open(application::palette::PaletteMode mode) {
    parent_.reset();
    editor_restore_ = {};
    if (mode == application::palette::PaletteMode::suggest) {
      application::palette::suggest(store_.session());
    }

    query_ = QChar{static_cast<char>(mode)};
    selection_ = 0;
    ++revision_;
    static_cast<void>(updateResults());
    emit changed();
  }

  void PaletteController::forget() noexcept {
    parent_.reset();
    editor_restore_ = {};
  }

  void PaletteController::publish() {
    emit changed();
  }

  void PaletteController::reportQueryLimit(qulonglong requested_bytes) {
    if (!isOpen() || requested_bytes <= application::palette::PaletteQuery::maximum_bytes) {
      return;
    }

    store_.session().reportLimit({.name = "prompt.field_bytes", .noun = "bytes", .value = application::palette::PaletteQuery::maximum_bytes, .requested = requested_bytes, .route = {}});
    store_.commit();
  }

  void PaletteController::search(const QString& text) {
    if (!isOpen() || text == query_) {
      return;
    }

    const auto before_bytes = query_.toUtf8();
    const auto before = application::palette::PaletteQuery::parse(paletteBytes(before_bytes));
    const auto measured = Utf16Prefix::fit(QStringView{text}, application::palette::PaletteQuery::maximum_bytes, utf16Encoding());

    query_ = text.first(static_cast<qsizetype>(measured.units));
    if (!query_.isValidUtf16()) {
      query_ = QString::fromUtf8(query_.toUtf8());
    }

    selection_ = 0;
    const auto current_bytes = query_.toUtf8();
    const auto current = application::palette::PaletteQuery::parse(paletteBytes(current_bytes));
    if (current.mode == application::palette::PaletteMode::suggest && (before.mode != application::palette::PaletteMode::suggest || before.text != current.text)) {
      application::palette::discard(store_.session());
    }

    static_cast<void>(updateResults());
    emit changed();

    if (measured.bytes < measured.requested_bytes) {
      reportQueryLimit(static_cast<qulonglong>(measured.requested_bytes));
    }
  }

  void PaletteController::move(int delta) {
    if (!isOpen() || rows_.empty()) {
      return;
    }

    const auto last = rows_.size() - 1;
    const auto selected = std::clamp(static_cast<qsizetype>(selection_) + delta, qsizetype{0}, last);
    if (std::cmp_not_equal(selected, selection_)) {
      selection_ = static_cast<std::size_t>(selected);
      emit changed();
    }
  }

  void PaletteController::setMode(int mode) {
    const auto prefix = application::palette::PaletteQuery::prefix(static_cast<char>(mode));
    const auto current = query_.toUtf8();
    if (!isOpen() || !prefix || mode != static_cast<int>(*prefix) || application::palette::PaletteQuery::parse(paletteBytes(current)).mode == *prefix) {
      return;
    }

    auto replacement = query_;

    if (!current.isEmpty() && application::palette::PaletteQuery::prefix(current.front())) {
      replacement.remove(0, 1);
    }

    replacement.prepend(QChar{static_cast<char>(*prefix)});
    search(replacement);
  }

  void PaletteController::synchronize() {
    if (isOpen() && updateResults()) {
      emit changed();
    }
  }

  void PaletteController::refreshMachines() {
    if (query().startsWith(QLatin1Char(':'))) {
      synchronize();
    }
  }

  void PaletteController::collectNavigation(Matches& matches, std::string_view query) const {
    const auto& session = store_.session();

    for (const auto& workspace : session.workspaces()) {
      application::palette::NavigationLabel label;

      label.append(workspace.name);
      label.appendDetail(workspace.branch);
      matches.add(NavigationTarget{workspace.location}, label.view(), query);
    }

    std::array<const Tab<Memory>*, GuiSession::maximum_workspace_tabs> tabs{};
    std::size_t count = 0;
    const auto* active = session.activeTab();

    for (const auto& tab : session.tabs()) {
      if (active != nullptr && sameWorkspace(tab->location.workspace, active->location.workspace) && count < tabs.size()) {
        tabs[count++] = tab.get();
      }
    }

    const auto ordered = std::span{tabs}.first(count);

    std::ranges::sort(ordered, {}, &Tab<Memory>::position);
    for (const auto* tab : ordered) {
      application::palette::NavigationLabel label;

      label.append(application::palette::NavigationLabel::tab_prefix);
      label.append(tab->label.empty() ? application::tabApplicationName(*tab, session.findPane(tab->focused_pane)) : std::string_view{tab->label});
      matches.add(NavigationTarget{tab->location}, label.view(), query);
    }

    for (const auto& agent : session.agents()) {
      application::palette::NavigationLabel label;

      label.append(agent.provider_name);
      label.appendDetail(agent.title);
      label.appendDetail(agent.workspace_label);
      matches.add(NavigationTarget{AgentNavigationTarget{.pane_id = agent.pane_id, .pane_generation = agent.pane_generation}}, label.view(), query);
    }
  }

  bool PaletteController::updateResults() {
    const auto text = query_.toUtf8();
    const auto query = application::palette::PaletteQuery::parse(paletteBytes(text));
    if (query.mode == application::palette::PaletteMode::machines) {
      return updateMachineResults(query.text);
    }

    Matches matches;

    if (query.mode == application::palette::PaletteMode::navigate) {
      collectNavigation(matches, query.text);
    } else if (query.mode == application::palette::PaletteMode::actions) {
      for (const auto& entry : commands_) {
        const auto command = entry.toMap();
        const auto label = command.value(QStringLiteral("label")).toString().toUtf8();

        matches.add(PaletteAction{.value = command.value(QStringLiteral("action")).toInt()}, paletteBytes(label), query.text);
      }
    }

    QVariantList rows;

    rows.reserve(static_cast<qsizetype>(matches.rows().size()));
    for (const auto& match : matches.rows()) {
      rows.append(record(match.target, !query.text.empty()));
    }

    if (rows == rows_) {
      return false;
    }

    for (std::size_t index = 0; index < matches.rows().size(); ++index) {
      targets_[index] = matches.rows()[index].target;
      kinds_[index] = static_cast<application::palette::PaletteRowKind>(rows[static_cast<qsizetype>(index)].toMap().value(QStringLiteral("kind")).toInt());
    }

    rows_ = std::move(rows);
    selection_ = rows_.empty() ? 0 : std::min(selection_, static_cast<std::size_t>(rows_.size() - 1));
    ++revision_;
    ++rebuilds_;

    return true;
  }

  bool PaletteController::updateMachineResults(std::string_view query) {
    const auto matches = MachinePicker::collect(store_.machines(), query);
    QVariantList rows;

    rows.reserve(static_cast<qsizetype>(matches.rows().size()) + 1);
    for (const auto& match : matches.rows()) {
      rows.append(machineRecord({.machine = match.target}));
    }

    rows.append(machineRecord({.machine = std::nullopt}));
    if (rows == rows_) {
      return false;
    }

    for (std::size_t index = 0; index < matches.rows().size(); ++index) {
      targets_[index] = MachinePickerTarget{.machine = matches.rows()[index].target};
      kinds_[index] = application::palette::PaletteRowKind::machine;
    }

    const auto last = matches.rows().size();

    targets_[last] = MachinePickerTarget{.machine = std::nullopt};
    kinds_[last] = application::palette::PaletteRowKind::machine;
    rows_ = std::move(rows);
    selection_ = std::min(selection_, static_cast<std::size_t>(rows_.size() - 1));
    ++revision_;
    ++rebuilds_;

    return true;
  }

  QVariantMap PaletteController::record(const PaletteTarget& target, bool queried) const {
    if (const auto* action = std::get_if<PaletteAction>(&target)) {
      for (const auto& entry : commands_) {
        const auto command = entry.toMap();
        if (command.value(QStringLiteral("action")).toInt() == action->value) {
          return {
              {QStringLiteral("key"), QStringLiteral("action:") + QString::number(action->value)},
              {QStringLiteral("kind"), static_cast<int>(application::palette::PaletteRowKind::action)},
              {QStringLiteral("icon"), QStringLiteral("")},
              {QStringLiteral("primary"), command.value(QStringLiteral("label"))},
              {QStringLiteral("secondary"), QString{}},
              {QStringLiteral("hint"), command.value(QStringLiteral("shortcut"))},
              {QStringLiteral("shortcut"), true},
              {QStringLiteral("detailBelow"), false},
          };
        }
      }

      return {};
    }

    const auto& session = store_.session();
    const auto& navigation = std::get<NavigationTarget>(target);
    application::palette::NavigationLabel label;

    if (const auto* workspace = std::get_if<WorkspaceLocation>(&navigation)) {
      const auto found = std::ranges::find_if(session.workspaces(), [&](const auto& row) {
        return sameWorkspace(row.location, *workspace);
      });
      if (found != session.workspaces().end()) {
        label.append(found->name);
        label.appendDetail(found->branch);
      }

      return navigationRecord(navigation, label, application::palette::PaletteRowKind::context, queried);
    }

    if (const auto* tab = std::get_if<TabLocation>(&navigation)) {
      const auto found = std::ranges::find_if(session.tabs(), [&](const auto& row) {
        return sameTab(row->location, *tab);
      });
      if (found != session.tabs().end()) {
        label.append(application::palette::NavigationLabel::tab_prefix);
        label.append((*found)->label.empty() ? application::tabApplicationName(*(*found), session.findPane((*found)->focused_pane)) : std::string_view{(*found)->label});
      }

      return navigationRecord(navigation, label, application::palette::PaletteRowKind::tab, queried);
    }

    const auto identity = std::get<AgentNavigationTarget>(navigation);
    const auto found = std::ranges::find_if(session.agents(), [&](const auto& row) {
      return row.pane_id == identity.pane_id && row.pane_generation == identity.pane_generation;
    });
    if (found == session.agents().end()) {
      return {};
    }

    label.append(found->provider_name);
    auto result = navigationRecord(navigation, label, application::palette::PaletteRowKind::agent, false);
    constexpr std::string_view separator = " · ";
    const auto detail_size = found->provider_name.size() + separator.size() + found->workspace_label.size();
    if (detail_size <= application::palette::NavigationLabel::capacity) {
      label.append(separator);
      label.append(found->workspace_label);
    }

    result.insert(QStringLiteral("primary"), toQString(found->title.empty() ? std::string_view{found->provider_name} : std::string_view{found->title}));
    result.insert(QStringLiteral("secondary"), toQString(label.view()));
    result.insert(QStringLiteral("hint"), QString{});
    result.insert(QStringLiteral("detailBelow"), true);

    return result;
  }

  QVariantMap PaletteController::machineRecord(MachinePickerTarget target) const {
    QVariantMap result{
        {QStringLiteral("kind"), static_cast<int>(application::palette::PaletteRowKind::machine)},
        {QStringLiteral("detailBelow"), false},
        {QStringLiteral("shortcut"), false},
    };

    if (!target.machine) {
      result.insert(QStringLiteral("key"), QStringLiteral("machine:add"));
      result.insert(QStringLiteral("icon"), QStringLiteral("+"));
      result.insert(QStringLiteral("primary"), QStringLiteral("Add machine…"));
      result.insert(QStringLiteral("secondary"), QStringLiteral("a label and its SSH destination"));
      result.insert(QStringLiteral("hint"), QString{});

      return result;
    }

    const auto token = *target.machine;
    const auto& row = store_.machines().row(token.slot);
    QString state;

    if (!row.enabled) {
      state = QStringLiteral("disabled · enter enables");
    } else if (token.slot == store_.machines().active()) {
      state = QStringLiteral("shown");
    } else {
      switch (row.phase) {
      case MachinePhase::connected:
        state = row.cpu_percent ? QString::number(*row.cpu_percent) + QStringLiteral("% cpu") : QStringLiteral("connected");
        break;
      case MachinePhase::connecting:
        state = QStringLiteral("connecting");
        break;
      case MachinePhase::lost:
        state = QStringLiteral("unreachable · enter retries");
        break;
      case MachinePhase::failed:
        state = row.needs_setup ? QStringLiteral("no telar for this build · enter sets it up") : QStringLiteral("failed · enter retries");
        break;
      case MachinePhase::stopped:
        state = QStringLiteral("disabled");
        break;
      }
    }

    result.insert(QStringLiteral("key"), QStringLiteral("machine:") + QString::number(token.slot) + QLatin1Char(':') + QString::number(token.generation));
    result.insert(QStringLiteral("icon"), row.attention ? QStringLiteral("●") : QStringLiteral("○"));
    result.insert(QStringLiteral("primary"), toQString(row.label.view()));
    result.insert(QStringLiteral("secondary"), row.destination.view().empty() ? QStringLiteral("this machine") : toQString(row.destination.view()));
    result.insert(QStringLiteral("hint"), state);

    return result;
  }

  QVariantMap PaletteController::state() const {
    const auto text = query_.toUtf8();
    const auto query = application::palette::PaletteQuery::parse(paletteBytes(text));
    const auto selected = static_cast<qsizetype>(selection_);

    return {
        {QStringLiteral("mode"), static_cast<int>(query.mode)},
        {QStringLiteral("editorText"), query_},
        {QStringLiteral("query"), toQString(query.text)},
        {QStringLiteral("selection"), selected},
        {QStringLiteral("selectedKey"), selected < rows_.size() ? rows_[selected].toMap().value(QStringLiteral("key")) : QVariant{}},
        {QStringLiteral("revision"), QString::number(revision_)},
        {QStringLiteral("count"), rows_.size()},
        {QStringLiteral("maximumQueryBytes"), static_cast<qulonglong>(application::palette::PaletteQuery::maximum_bytes)},
        {QStringLiteral("editorRestoreRevision"), editor_restore_.revision == 0 ? QString{} : QString::number(editor_restore_.revision)},
        {QStringLiteral("editorAnchor"), editor_restore_.anchor},
        {QStringLiteral("editorCursor"), editor_restore_.cursor},
    };
  }

  QVariantMap PaletteController::geometry() const {
    const auto density = display_.density;
    const Rect viewport{.width = static_cast<float>(display_.viewport.width), .height = static_cast<float>(display_.viewport.height)};
    const auto text = query_.toUtf8();
    const auto query = application::palette::PaletteQuery::parse(paletteBytes(text));
    const auto geometry = application::palette::PaletteGeometry::measure(viewport, display_.chrome, {.pick_rows = std::nullopt, .suggest = query.mode == application::palette::PaletteMode::suggest});
    const auto local = [&](Rect area) {
      area.x -= geometry.bounds.x;
      area.y -= geometry.bounds.y;

      return toQRectF(area, density);
    };

    const auto kinds = std::span{kinds_}.first(static_cast<std::size_t>(rows_.size()));
    const auto visible = application::palette::PaletteRowWindow::measure(kinds, selection_, geometry, display_.chrome, query.text.empty());
    QVariantList rows;

    rows.reserve(static_cast<qsizetype>(visible.count));
    for (std::size_t index = 0; index < visible.count; ++index) {
      const auto& placement = visible.rows[index];
      auto record = rows_[static_cast<qsizetype>(placement.index)].toMap();

      record.insert(QStringLiteral("bounds"), local(placement.bounds));
      record.insert(QStringLiteral("groupBounds"), local(placement.group));
      record.insert(QStringLiteral("groupLabel"), groupName(kinds[placement.index]));
      record.insert(QStringLiteral("selected"), placement.index == selection_);
      rows.append(QVariant{std::in_place_type<QVariantMap>, std::move(record)});
    }

    return {
        {QStringLiteral("bounds"), toQRectF(geometry.bounds, density)},
        {QStringLiteral("heading"), local(geometry.heading)},
        {QStringLiteral("search"), local(geometry.search)},
        {QStringLiteral("tabs"), local(geometry.tabs)},
        {QStringLiteral("results"), local(geometry.results)},
        {QStringLiteral("footer"), local(geometry.footer)},
        {QStringLiteral("rows"), rows},
    };
  }

  std::optional<PaletteController::Choice> PaletteController::chosen(const QVariantMap& choice) const {
    const auto key = choice.value(QStringLiteral("key")).toString();
    const auto revision = choice.value(QStringLiteral("revision")).toString();
    if (!isOpen() || revision != QString::number(revision_)) {
      return std::nullopt;
    }

    const auto found = std::ranges::find_if(rows_, [&](const auto& entry) {
      return entry.toMap().value(QStringLiteral("key")).toString() == key;
    });
    if (found == rows_.end()) {
      return std::nullopt;
    }

    const auto index = static_cast<std::size_t>(found - rows_.begin());

    return Choice{.target = targets_[index], .index = index};
  }

  std::optional<MachinePickerTarget> PaletteController::chosenMachine(const QVariantMap& choice) const {
    if (!isOpen() || choice.value(QStringLiteral("revision")).toString() != QString::number(revision_)) {
      return std::nullopt;
    }

    const auto key = choice.value(QStringLiteral("key")).toString();

    for (qsizetype index = 0; index < rows_.size(); ++index) {
      if (rows_[index].toMap().value(QStringLiteral("key")).toString() == key) {
        if (const auto* target = std::get_if<MachinePickerTarget>(&targets_[static_cast<std::size_t>(index)])) {
          return *target;
        }
      }
    }

    return std::nullopt;
  }

  PaletteController::Parent PaletteController::parentFor(const QVariantMap& choice, std::size_t index) const {
    const auto cursor = choice.value(QStringLiteral("cursor"), query_.size()).toInt();
    const auto anchor = choice.value(QStringLiteral("anchor"), cursor).toInt();

    return {.query = query_, .selection = index, .editor = {.anchor = std::clamp(anchor, 0, static_cast<int>(query_.size())), .cursor = std::clamp(cursor, 0, static_cast<int>(query_.size()))}};
  }

  void PaletteController::adoptParent(Parent parent) {
    parent_ = std::move(parent);
    emit changed();
  }

  bool PaletteController::restoreParent() {
    if (!isOpen() || !parent_) {
      return false;
    }

    auto parent = std::move(*parent_);

    open(application::palette::PaletteMode::actions);
    query_ = std::move(parent.query);
    selection_ = parent.selection;
    static_cast<void>(updateResults());
    editor_restore_ = parent.editor;
    editor_restore_.revision = ++revision_;
    emit changed();
    emit showRequested();

    return true;
  }

  void PaletteController::activate(const QVariantMap& choice) {
    const auto found = chosen(choice);
    if (!found) {
      return;
    }

    const auto& target = found->target;
    if (const auto* machine = std::get_if<MachinePickerTarget>(&target)) {
      emit machineRequested(*machine, choice.value(QStringLiteral("alternate"), false).toBool());

      return;
    }

    if (const auto* navigation = std::get_if<NavigationTarget>(&target)) {
      interact([&] {
        if (navigate(*navigation)) {
          emit closeRequested();
        }
      });

      return;
    }

    const auto action = std::get<PaletteAction>(target);
    if (action.value != suggestion_.value) {
      emit actionRequested(action);

      return;
    }

    interact([&] {
      auto parent = parentFor(choice, found->index);

      open(application::palette::PaletteMode::suggest);
      emit showRequested();
      adoptParent(std::move(parent));
    });
  }

  bool PaletteController::navigate(const NavigationTarget& target) {
    auto& session = store_.session();

    if (const auto* workspace = std::get_if<WorkspaceLocation>(&target)) {
      const auto found = std::ranges::find_if(session.workspaces(), [&](const auto& row) {
        return sameWorkspace(row.location, *workspace);
      });
      if (found == session.workspaces().end()) {
        return false;
      }

      session.selectWorkspace(*workspace);

      return true;
    }

    if (const auto* tab = std::get_if<TabLocation>(&target)) {
      const auto found = std::ranges::find_if(session.tabs(), [&](const auto& row) {
        return sameTab(row->location, *tab);
      });
      if (found == session.tabs().end()) {
        return false;
      }

      session.selectTab(*tab);

      return true;
    }

    const auto agent = std::get<AgentNavigationTarget>(target);

    return session.focusAgent(agent.pane_id, agent.pane_generation);
  }

  void PaletteController::submitSuggestion(const QString& revision) {
    const auto encoded = query_.toUtf8();
    const auto query = application::palette::PaletteQuery::parse(paletteBytes(encoded));
    if (!isOpen() || query.mode != application::palette::PaletteMode::suggest || revision != suggestionRevision()) {
      return;
    }

    interact([&] {
      if (application::palette::submit(store_.session(), query.text)) {
        emit closeRequested();
      }

      publish();
    });
  }

  QString PaletteController::suggestionRevision() const {
    return QString::number(store_.dialog().generation) + QLatin1Char(':') + QString::number(application::palette::suggestion(store_.session()).revision);
  }

  QVariantMap PaletteController::suggestion() const {
    const auto suggestion = application::palette::suggestion(store_.session());
    const auto phase = suggestion.phase;
    const auto encoded = query_.toUtf8();
    const auto query = application::palette::PaletteQuery::parse(paletteBytes(encoded));

    return {
        {QStringLiteral("heading"), toQString(application::palette::SuggestionLabels::heading(phase))},
        {QStringLiteral("message"), toQString(application::palette::SuggestionLabels::message(phase, suggestion.status))},
        {QStringLiteral("button"), toQString(application::palette::SuggestionLabels::button(phase))},
        {QStringLiteral("footer"), toQString(application::palette::SuggestionLabels::footer(phase))},
        {QStringLiteral("text"), toQString(suggestion.text)},
        {QStringLiteral("phase"), static_cast<int>(phase)},
        {QStringLiteral("ready"), phase == application::palette::SuggestionPhase::ready},
        {QStringLiteral("failed"), phase == application::palette::SuggestionPhase::failed},
        {QStringLiteral("canSubmit"), application::palette::SuggestionLabels::canSubmit(phase, query.text)},
        {QStringLiteral("revision"), suggestionRevision()},
        {QStringLiteral("hasParent"), parent_.has_value()},
    };
  }

  QVariantMap PaletteController::suggestionGeometry() const {
    const auto density = display_.density;
    const Rect viewport{.width = static_cast<float>(display_.viewport.width), .height = static_cast<float>(display_.viewport.height)};
    const auto palette = application::palette::PaletteGeometry::measure(viewport, display_.chrome, {.pick_rows = std::nullopt, .suggest = true});
    const auto geometry = application::palette::SuggestionGeometry::measure(palette, display_.chrome, parent_.has_value());
    const auto local = [&](Rect area) {
      area.x -= palette.bounds.x;
      area.y -= palette.bounds.y;

      return toQRectF(area, density);
    };

    const auto& session = store_.session();
    const auto suggestion = application::palette::suggestion(session);
    QVariantList lines;
    QVariantMap grid;

    if (suggestion.phase == application::palette::SuggestionPhase::ready) {
      const auto& font = session.configuration().font;
      const auto resolved = FormTextGrid::resolve(toQString(font.family.view()), toQString(font.style.view()), display_.chrome.body);

      grid = resolved.record(density);
      SuggestionPreview preview{suggestion.text, geometry.preview, resolved.metrics};

      while (const auto line = preview.next()) {
        lines.append(QVariantMap{{QStringLiteral("text"), toQString(line->text)}, {QStringLiteral("bounds"), local(line->bounds)}, {QStringLiteral("shortened"), line->shortened}});
      }
    }

    return {
        {QStringLiteral("title"), local(geometry.title)},
        {QStringLiteral("back"), local(geometry.back)},
        {QStringLiteral("heading"), local(geometry.heading)},
        {QStringLiteral("body"), local(geometry.body)},
        {QStringLiteral("message"), local(geometry.message)},
        {QStringLiteral("preview"), local(geometry.preview)},
        {QStringLiteral("footer"), local(geometry.footer_caption)},
        {QStringLiteral("button"), local(geometry.button)},
        {QStringLiteral("separator"), local(geometry.separator)},
        {QStringLiteral("previewRadius"), display_.chrome.px(application::palette::SuggestionGeometry::preview_radius) / density},
        {QStringLiteral("messageAlpha"), application::palette::SuggestionGeometry::message_alpha},
        {QStringLiteral("titleAlpha"), application::palette::SuggestionGeometry::title_alpha},
        {QStringLiteral("grid"), std::move(grid)},
        {QStringLiteral("lines"), std::move(lines)},
    };
  }

}

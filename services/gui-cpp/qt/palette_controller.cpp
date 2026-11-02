#include "application.hpp"
#include "application/dependencies.hpp"
#include "application/records.hpp"
#include "core/geometry.hpp"
#include "machines/picker_target.hpp"
#include "palette/navigation_label.hpp"
#include "palette/navigation_target.hpp"
#include "palette/query.hpp"
#include "presentation/palette_geometry.hpp"
#include "presentation/palette_row_window.hpp"
#include "projection.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "text/utf16_prefix.hpp"
#include "qt/utf16_encoding.hpp"
#include <QByteArray>
#include <QChar>
#include <QLatin1StringView>
#include <QQuickWindow>
#include <QString>
#include <QStringView>
#include <QVariantList>
#include <QVariantMap>
#include <QVariant>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstringfwd.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <string_view>
#include <utility>
#include <variant>

namespace telar::gui::qt {

namespace {

std::string_view bytes(const QByteArray &text) {
  return {text.constData(), static_cast<std::size_t>(text.size())};
}

QString navigationKey(const NavigationTarget &target) {
  if (const auto *workspace = std::get_if<WorkspaceLocation>(&target)) {
    return QStringLiteral("context:") + QString::number(workspace->id);
  }

  if (const auto *tab = std::get_if<TabLocation>(&target)) {
    return QStringLiteral("tab:") + QString::number(static_cast<int>(tab->workspace.kind)) + QLatin1Char(':') + QString::number(tab->workspace.id) + QLatin1Char(':') + QString::number(tab->tab_id);
  }

  const auto agent = std::get<AgentNavigationTarget>(target);

  return QStringLiteral("agent:") + QString::number(agent.pane_id) + QLatin1Char(':') + QString::number(agent.pane_generation);
}

QString groupName(PaletteRowKind kind) {
  switch (kind) {
  case PaletteRowKind::context:
    return QStringLiteral("Contexts");
  case PaletteRowKind::tab:
    return QStringLiteral("Tabs");
  case PaletteRowKind::agent:
    return QStringLiteral("Agents");
  case PaletteRowKind::action:
    return QStringLiteral("Actions");
  case PaletteRowKind::machine:
    return QStringLiteral("Machines");
  default:
    return {};
  }
}

QVariantMap navigationRecord(const NavigationTarget &target, const NavigationLabel &label, PaletteRowKind kind, bool queried) {
  const auto text = label.view();
  const auto split = std::min(text.find(NavigationLabel::detail_separator), text.size());
  auto primary = text.substr(0, split);
  auto secondary = text.substr(split);
  secondary.remove_prefix(std::min(secondary.find_first_not_of(' '), secondary.size()));
  if (kind == PaletteRowKind::tab && primary.starts_with(NavigationLabel::tab_prefix)) {
    primary.remove_prefix(NavigationLabel::tab_prefix.size());
  }

  QString glyph = QStringLiteral("\uf121");
  if (kind == PaletteRowKind::context) {
    glyph = QStringLiteral("\uf07b");
  } else if (kind == PaletteRowKind::tab) {
    glyph = QStringLiteral("\uf2d0");
  }
  const auto hint = kind == PaletteRowKind::context ? QStringLiteral("context") : QStringLiteral("tab");

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

void Application::showPalette(PaletteMode mode) {
  palette_parent_.reset();
  palette_editor_restore_ = {};
  if (mode == PaletteMode::suggest) {
    session().beginSuggestion();
  }

  palette_query_ = QChar{static_cast<char>(mode)};
  palette_selection_ = 0;
  ++palette_revision_;
  showDialog(QStringLiteral("palette"));
  static_cast<void>(updatePaletteResults());
  emit paletteChanged();
}

void Application::reportPaletteQueryLimit(qulonglong requested_bytes) {
  if (dialog_ == QLatin1StringView("palette") && requested_bytes > PaletteQuery::maximum_bytes) {
    session().reportLimit({.name = "prompt.field_bytes", .noun = "bytes", .value = PaletteQuery::maximum_bytes, .requested = requested_bytes, .route = {}});
    refreshNotifications();
  }
}

void Application::searchPalette(const QString &text) {
  if (dialog_ != QLatin1StringView("palette") || text == palette_query_) {
    return;
  }

  const auto before_bytes = palette_query_.toUtf8();
  const auto before = PaletteQuery::parse(bytes(before_bytes));
  const auto measured = Utf16Prefix::fit(QStringView{text}, PaletteQuery::maximum_bytes, utf16Encoding());
  palette_query_ = text.first(static_cast<qsizetype>(measured.units));
  if (!palette_query_.isValidUtf16()) {
    palette_query_ = QString::fromUtf8(palette_query_.toUtf8());
  }

  palette_selection_ = 0;
  const auto current_bytes = palette_query_.toUtf8();
  const auto current = PaletteQuery::parse(bytes(current_bytes));
  if (current.mode == PaletteMode::suggest && (before.mode != PaletteMode::suggest || before.text != current.text)) {
    session().invalidateSuggestion();
  }

  static_cast<void>(updatePaletteResults());
  emit paletteChanged();

  if (measured.bytes < measured.requested_bytes) {
    reportPaletteQueryLimit(static_cast<qulonglong>(measured.requested_bytes));
  }
}

void Application::movePalette(int delta) {
  if (dialog_ != QLatin1StringView("palette") || palette_rows_.empty()) {
    return;
  }

  const auto last = palette_rows_.size() - 1;
  const auto selected = std::clamp(static_cast<qsizetype>(palette_selection_) + delta, qsizetype{0}, last);
  if (std::cmp_not_equal(selected, palette_selection_)) {
    palette_selection_ = static_cast<std::size_t>(selected);
    emit paletteChanged();
  }
}

void Application::setPaletteMode(int mode) {
  const auto prefix = PaletteQuery::prefix(static_cast<char>(mode));
  const auto current = palette_query_.toUtf8();
  if (dialog_ != QLatin1StringView("palette") || !prefix || mode != static_cast<int>(*prefix) || PaletteQuery::parse(bytes(current)).mode == *prefix) {
    return;
  }

  auto replacement = palette_query_;
  if (!current.isEmpty() && PaletteQuery::prefix(current.front())) {
    replacement.remove(0, 1);
  }

  replacement.prepend(QChar{static_cast<char>(*prefix)});
  searchPalette(replacement);
}

void Application::refreshPalette() {
  if (dialog_ == QLatin1StringView("palette") && updatePaletteResults()) {
    emit paletteChanged();
  }
}

void Application::collectPaletteNavigation(PaletteMatches &matches, std::string_view query) const {
  for (const auto &workspace : session().workspaces()) {
    NavigationLabel label;
    label.append(workspace.name);
    label.appendDetail(workspace.branch);
    matches.add(NavigationTarget{workspace.location}, label.view(), query);
  }

  std::array<const Tab<ApplicationAllocator> *, GuiSession::maximum_workspace_tabs> tabs{};
  std::size_t count = 0;
  const auto *active = session().activeTab();
  for (const auto &tab : session().tabs()) {
    if (active != nullptr && sameWorkspace(tab->location.workspace, active->location.workspace) && count < tabs.size()) {
      tabs[count++] = tab.get();
    }
  }

  const auto ordered = std::span{tabs}.first(count);
  std::ranges::sort(ordered, {}, &Tab<ApplicationAllocator>::position);
  for (const auto *tab : ordered) {
    NavigationLabel label;
    label.append(NavigationLabel::tab_prefix);
    label.append(tab->label.empty() ? tab->applicationName(session().findPane(tab->focused_pane)) : std::string_view{tab->label});
    matches.add(NavigationTarget{tab->location}, label.view(), query);
  }

  for (const auto &agent : session().agents()) {
    NavigationLabel label;
    label.append(agent.provider_name);
    label.appendDetail(agent.title);
    label.appendDetail(agent.workspace_label);
    matches.add(NavigationTarget{AgentNavigationTarget{.pane_id = agent.pane_id, .pane_generation = agent.pane_generation}}, label.view(), query);
  }
}

bool Application::updatePaletteResults() {
  const auto text = palette_query_.toUtf8();
  const auto query = PaletteQuery::parse(bytes(text));
  if (query.mode == PaletteMode::machines) {
    return updateMachinePickerResults(query.text);
  }

  PaletteMatches matches;
  if (query.mode == PaletteMode::navigate) {
    collectPaletteNavigation(matches, query.text);
  } else if (query.mode == PaletteMode::actions) {
    palette_commands_ = commands();
    for (const auto &entry : palette_commands_) {
      const auto command = entry.toMap();
      const auto label = command.value(QStringLiteral("label")).toString().toUtf8();
      matches.add(command.value(QStringLiteral("action")).value<Action>(), bytes(label), query.text);
    }
  }

  QVariantList rows;
  rows.reserve(static_cast<qsizetype>(matches.rows().size()));
  for (const auto &match : matches.rows()) {
    rows.append(paletteRecord(match.target, !query.text.empty()));
  }

  if (rows == palette_rows_) {
    return false;
  }

  for (std::size_t index = 0; index < matches.rows().size(); ++index) {
    palette_targets_[index] = matches.rows()[index].target;
    palette_kinds_[index] = static_cast<PaletteRowKind>(rows[static_cast<qsizetype>(index)].toMap().value(QStringLiteral("kind")).toInt());
  }

  palette_rows_ = std::move(rows);
  palette_selection_ = palette_rows_.empty() ? 0 : std::min(palette_selection_, static_cast<std::size_t>(palette_rows_.size() - 1));
  ++palette_revision_;

  return true;
}

QVariantMap Application::paletteRecord(const PaletteTarget &target, bool queried) const {
  if (const auto *action = std::get_if<Action>(&target)) {
    for (const auto &entry : palette_commands_) {
      const auto command = entry.toMap();
      if (command.value(QStringLiteral("action")).value<Action>() == *action) {
        return {
            {QStringLiteral("key"), QStringLiteral("action:") + QString::number(static_cast<int>(*action))},
            {QStringLiteral("kind"), static_cast<int>(PaletteRowKind::action)},
            {QStringLiteral("icon"), QStringLiteral("\uf105")},
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

  const auto &navigation = std::get<NavigationTarget>(target);
  NavigationLabel label;
  if (const auto *workspace = std::get_if<WorkspaceLocation>(&navigation)) {
    const auto found = std::ranges::find_if(session().workspaces(), [&](const auto &row) {
      return sameWorkspace(row.location, *workspace);
    });
    if (found != session().workspaces().end()) {
      label.append(found->name);
      label.appendDetail(found->branch);
    }

    return navigationRecord(navigation, label, PaletteRowKind::context, queried);
  }

  if (const auto *tab = std::get_if<TabLocation>(&navigation)) {
    const auto found = std::ranges::find_if(session().tabs(), [&](const auto &row) {
      return sameTab(row->location, *tab);
    });
    if (found != session().tabs().end()) {
      label.append(NavigationLabel::tab_prefix);
      label.append((*found)->label.empty() ? (*found)->applicationName(session().findPane((*found)->focused_pane)) : std::string_view{(*found)->label});
    }

    return navigationRecord(navigation, label, PaletteRowKind::tab, queried);
  }

  const auto identity = std::get<AgentNavigationTarget>(navigation);
  const auto found = std::ranges::find_if(session().agents(), [&](const auto &row) {
    return row.pane_id == identity.pane_id && row.pane_generation == identity.pane_generation;
  });
  if (found == session().agents().end()) {
    return {};
  }

  label.append(found->provider_name);
  auto result = navigationRecord(navigation, label, PaletteRowKind::agent, false);
  constexpr std::string_view separator = " · ";
  const auto detail_size = found->provider_name.size() + separator.size() + found->workspace_label.size();
  if (detail_size <= NavigationLabel::capacity) {
    label.append(separator);
    label.append(found->workspace_label);
  }

  result.insert(QStringLiteral("primary"), toQString(found->title.empty() ? std::string_view{found->provider_name} : std::string_view{found->title}));
  result.insert(QStringLiteral("secondary"), toQString(label.view()));
  result.insert(QStringLiteral("hint"), QString{});
  result.insert(QStringLiteral("detailBelow"), true);

  return result;
}

QVariantMap Application::paletteState() const {
  const auto text = palette_query_.toUtf8();
  const auto query = PaletteQuery::parse(bytes(text));
  const auto selected = static_cast<qsizetype>(palette_selection_);

  return {
      {QStringLiteral("mode"), static_cast<int>(query.mode)},
      {QStringLiteral("editorText"), palette_query_},
      {QStringLiteral("query"), toQString(query.text)},
      {QStringLiteral("selection"), selected},
      {QStringLiteral("selectedKey"), selected < palette_rows_.size() ? palette_rows_[selected].toMap().value(QStringLiteral("key")) : QVariant{}},
      {QStringLiteral("revision"), QString::number(palette_revision_)},
      {QStringLiteral("count"), palette_rows_.size()},
      {QStringLiteral("maximumQueryBytes"), static_cast<qulonglong>(PaletteQuery::maximum_bytes)},
      {QStringLiteral("editorRestoreRevision"), palette_editor_restore_.revision == 0 ? QString{} : QString::number(palette_editor_restore_.revision)},
      {QStringLiteral("editorAnchor"), palette_editor_restore_.anchor},
      {QStringLiteral("editorCursor"), palette_editor_restore_.cursor},
  };
}

QVariantMap Application::paletteGeometry() const {
  const auto density = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
  const auto display = displayMetrics(density);
  const Rect viewport{.width = static_cast<float>(display.viewport.width), .height = static_cast<float>(display.viewport.height)};
  const auto text = palette_query_.toUtf8();
  const auto query = PaletteQuery::parse(bytes(text));
  const auto geometry = PaletteGeometry::measure(viewport, display.chrome, {.pick_rows = std::nullopt, .suggest = query.mode == PaletteMode::suggest});
  const auto local = [&](Rect area) {
    area.x -= geometry.bounds.x;
    area.y -= geometry.bounds.y;

    return toQRectF(area, density);
  };

  const auto kinds = std::span{palette_kinds_}.first(static_cast<std::size_t>(palette_rows_.size()));
  const auto visible = PaletteRowWindow::measure(kinds, palette_selection_, geometry, display.chrome, query.text.empty());
  QVariantList rows;
  rows.reserve(static_cast<qsizetype>(visible.count));
  for (std::size_t index = 0; index < visible.count; ++index) {
    const auto &placement = visible.rows[index];
    auto record = palette_rows_[static_cast<qsizetype>(placement.index)].toMap();
    record.insert(QStringLiteral("bounds"), local(placement.bounds));
    record.insert(QStringLiteral("groupBounds"), local(placement.group));
    record.insert(QStringLiteral("groupLabel"), groupName(kinds[placement.index]));
    record.insert(QStringLiteral("selected"), placement.index == palette_selection_);
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

bool Application::navigatePaletteTarget(const NavigationTarget &target) {
  if (const auto *workspace = std::get_if<WorkspaceLocation>(&target)) {
    const auto found = std::ranges::find_if(session().workspaces(), [&](const auto &row) {
      return sameWorkspace(row.location, *workspace);
    });
    if (found == session().workspaces().end()) {
      return false;
    }

    session().selectWorkspace(*workspace);

    return true;
  }

  if (const auto *tab = std::get_if<TabLocation>(&target)) {
    const auto found = std::ranges::find_if(session().tabs(), [&](const auto &row) {
      return sameTab(row->location, *tab);
    });
    if (found == session().tabs().end()) {
      return false;
    }

    session().selectTab(*tab);

    return true;
  }

  const auto agent = std::get<AgentNavigationTarget>(target);

  return session().focusAgent(agent.pane_id, agent.pane_generation);
}

void Application::usePaletteResult(const QVariantMap &choice) {
  const auto key = choice.value(QStringLiteral("key")).toString();
  const auto revision = choice.value(QStringLiteral("revision")).toString();
  if (dialog_ != QLatin1StringView("palette") || revision != QString::number(palette_revision_)) {
    return;
  }

  const auto found = std::ranges::find_if(palette_rows_, [&](const auto &entry) {
    return entry.toMap().value(QStringLiteral("key")).toString() == key;
  });
  if (found == palette_rows_.end()) {
    return;
  }

  const auto index = static_cast<std::size_t>(found - palette_rows_.begin());
  const auto target = palette_targets_[index];
  applyInteraction([&] {
    if (const auto *machine = std::get_if<MachinePickerTarget>(&target)) {
      chooseMachine(*machine, choice.value(QStringLiteral("alternate"), false).toBool());

      return;
    }

    if (const auto *navigation = std::get_if<NavigationTarget>(&target)) {
      if (navigatePaletteTarget(*navigation)) {
        showDialog({});
      }

      return;
    }

    const auto action = std::get<Action>(target);
    if (action == Action::suggest_command) {
      const auto cursor = choice.value(QStringLiteral("cursor"), palette_query_.size()).toInt();
      const auto anchor = choice.value(QStringLiteral("anchor"), cursor).toInt();
      PaletteParent parent{.query = palette_query_, .selection = index, .editor = {.anchor = std::clamp(anchor, 0, static_cast<int>(palette_query_.size())), .cursor = std::clamp(cursor, 0, static_cast<int>(palette_query_.size()))}};
      showPalette(PaletteMode::suggest);
      palette_parent_ = std::move(parent);
      emit paletteChanged();

      return;
    }

    showDialog({});
    if (!executeNavigation(action, {}) && !executePane(action, 0)) {
      executeWindowAction(action);
    }
  });
}

}

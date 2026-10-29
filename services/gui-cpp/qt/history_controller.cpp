#include "application.hpp"
#include "application/dependencies.hpp"
#include "application/records.hpp"
#include "core/theme_values.hpp"
#include "history/browser.hpp"
#include "history/choice.hpp"
#include "history/entry.hpp"
#include "history/search.hpp"
#include "key_adapter.hpp"
#include "list_model.hpp"
#include "platform/wall_clock.hpp"
#include "platform/window.hpp"
#include "presentation/history_labels.hpp"
#include "presentation/history_inspection.hpp"
#include "presentation/history_path.hpp"
#include "presentation/tab_caption.hpp"
#include "text/bounded_text.hpp"
#include "projection.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <QClipboard>
#include <QGuiApplication>
#include <QtCore/qbytearrayview.h>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qlist.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qstring.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <cstddef>
#include <string_view>
#include <utility>

namespace telar::gui::qt {

namespace {

QString scopeName(HistoryScope scope) {
  switch (scope) {
  case HistoryScope::cwd:
    return QStringLiteral("cwd");
  case HistoryScope::workspace:
    return QStringLiteral("workspace");
  case HistoryScope::pane:
    return QStringLiteral("pane");
  default:
    return QStringLiteral("global");
  }
}

QString authorName(HistoryAuthorFilter author) {
  switch (author) {
  case HistoryAuthorFilter::human:
    return QStringLiteral("human");
  case HistoryAuthorFilter::agent:
    return QStringLiteral("agent");
  default:
    return QStringLiteral("all");
  }
}

HistoryScope parseScope(const QString &scope) {
  for (const auto candidate : {HistoryScope::global, HistoryScope::cwd, HistoryScope::workspace, HistoryScope::pane}) {
    if (scopeName(candidate) == scope) {
      return candidate;
    }
  }

  throw EncodingError{"Unknown history scope"};
}

HistoryAuthorFilter parseAuthor(const QString &author) {
  for (const auto candidate : {HistoryAuthorFilter::all, HistoryAuthorFilter::human, HistoryAuthorFilter::agent}) {
    if (authorName(candidate) == author) {
      return candidate;
    }
  }

  throw EncodingError{"Unknown history author filter"};
}

QString phaseName(HistoryPhase phase) {
  switch (phase) {
  case HistoryPhase::loading:
    return QStringLiteral("loading");
  case HistoryPhase::ready:
    return QStringLiteral("ready");
  case HistoryPhase::failed:
    return QStringLiteral("failed");
  default:
    return QStringLiteral("idle");
  }
}

}

void Application::refreshHistory() {
  const auto &browser = session_.historyBrowser();
  const auto scope_value = dialog_ == QLatin1StringView("history") ? historyScopeValue() : QString{};
  const auto selection = browser.state().selection;
  const auto *pane = dialog_ == QLatin1StringView("history") && selection < browser.rows().size() ? session_.findPane(browser.rows()[selection].pane_id) : nullptr;
  BoundedText<TabCaption::capacity> tab_name;
  tab_name.append(historyTabName(pane));
  const auto pane_open = pane != nullptr;
  if (history_view_version_ == browser.viewVersion() && history_scope_value_ == scope_value && history_pane_open_ == pane_open && history_tab_name_.view() == tab_name.view()) {
    return;
  }

  if (history_rows_version_ != browser.rowsVersion()) {
    const auto sampled = platform::WallClock::sample();
    history_calendar_ = sampled;
    QList<QVariantMap> rows;
    rows.reserve(static_cast<qsizetype>(browser.rows().size()));
    for (std::size_t index = 0; index < browser.rows().size(); ++index) {
      const auto &entry = browser.rows()[index];
      auto record = historyRecord(entry, sampled);
      const auto day = HistoryLabels::localDay(entry.started_at_ms, sampled.utc_offset_min);
      const auto group_ends = index + 1 == browser.rows().size() || day != HistoryLabels::localDay(browser.rows()[index + 1].started_at_ms, sampled.utc_offset_min);
      record.insert(QStringLiteral("groupEnds"), group_ends);
      rows.append(std::move(record));
    }

    history_.reconcile(std::move(rows));
    history_rows_version_ = browser.rowsVersion();
  }

  history_view_version_ = browser.viewVersion();
  history_scope_value_ = scope_value;
  history_pane_open_ = pane_open;
  history_tab_name_ = tab_name;
  emit historyChanged();
}

std::string_view Application::historyTabName(const Pane<ApplicationAllocator> *pane) const {
  if (pane != nullptr) {
    for (const auto &tab : session_.tabs()) {
      if (sameTab(tab->location, pane->location)) {
        return tab->label.empty() ? tab->applicationName(session_.findPane(tab->focused_pane)) : std::string_view{tab->label};
      }
    }
  }

  return {};
}

QString Application::historyScopeValue() {
  if (session_.historyBrowser().scope() == HistoryScope::workspace) {
    return workspace_context_.value(QStringLiteral("name")).toString();
  }

  if (session_.historyBrowser().scope() != HistoryScope::cwd) {
    return {};
  }

  const auto *pane = session_.focusedPane();
  if (pane == nullptr) {
    return {};
  }

  const QByteArrayView source{pane->cwd.data(), static_cast<qsizetype>(pane->cwd.size())};
  if (QByteArrayView{history_directory_source_} != source) {
    const auto compact = HistoryPath::compact(std::string_view{pane->cwd.data(), pane->cwd.size()});
    auto value = toQString(compact.view());
    history_directory_source_.assign(source);
    history_directory_value_ = std::move(value);
  }

  return history_directory_value_;
}

QVariantMap Application::historyState() const {
  const auto &browser = session_.historyBrowser();
  const auto &state = browser.state();
  const auto &rows = browser.rows();
  const bool selected_detail = state.selection < rows.size() && rows[state.selection].id == state.command_id;
  const auto query = history_query_.toUtf8();
  const auto parsed = HistorySearch::parse({query.constData(), static_cast<std::size_t>(query.size())}, history_filters_.failed_only);

  return {
      {QStringLiteral("phase"), phaseName(state.phase)},
      {QStringLiteral("hasPage"), state.has_page},
      {QStringLiteral("revision"), QString::number(browser.revision())},
      {QStringLiteral("scope"), scopeName(history_filters_.scope)},
      {QStringLiteral("effectiveScope"), scopeName(browser.scope())},
      {QStringLiteral("scopeValue"), history_scope_value_},
      {QStringLiteral("author"), authorName(history_filters_.author)},
      {QStringLiteral("failedOnly"), parsed.failed_only},
      {QStringLiteral("grouped"), parsed.query.empty()},
      {QStringLiteral("query"), toQString(parsed.query)},
      {QStringLiteral("editorText"), history_query_},
      {QStringLiteral("maximumQueryBytes"), static_cast<int>(HistorySearch::maximum_query_bytes)},
      {QStringLiteral("inspectionKey"), platform::usesCommandKey() ? QStringLiteral("⌃O") : QStringLiteral("Ctrl+O")},
      {QStringLiteral("macStyle"), platform::usesCommandKey()},
      {QStringLiteral("paneOpen"), state.selection < rows.size() && session_.findPane(rows[state.selection].pane_id) != nullptr},
      {QStringLiteral("commandLoaded"), state.selection < rows.size() && (rows[state.selection].command_complete || (selected_detail && state.command_phase == HistoryPhase::ready))},
      {QStringLiteral("canOlder"), browser.canPage(HistoryPage::older)},
      {QStringLiteral("hasMore"), state.has_more},
      {QStringLiteral("matchFuzzy"), browser.match() == HistoryMatch::fuzzy},
      {QStringLiteral("canNewer"), browser.canPage(HistoryPage::newer)},
      {QStringLiteral("offset"), static_cast<qulonglong>(state.page_offset)},
      {QStringLiteral("selection"), static_cast<int>(state.selection)},
      {QStringLiteral("count"), static_cast<int>(browser.rows().size())},
      {QStringLiteral("canSubmit"), browser.canSubmit()},
      {QStringLiteral("commandPhase"), phaseName(selected_detail ? state.command_phase : HistoryPhase::idle)},
      {QStringLiteral("enterRuns"), session_.configuration().history.enter_runs},
      {QStringLiteral("inspecting"), state.inspecting},
      {QStringLiteral("outputPhase"), phaseName(state.output_phase)},
      {QStringLiteral("outputTruncated"), state.output_truncated},
      {QStringLiteral("deleting"), browser.deleting()},
      {QStringLiteral("error"), toQString(browser.error())},
  };
}

QString Application::historyOutput() const {
  return toQString(session_.historyBrowser().output());
}

QString Application::historyCommand() const {
  return toQString(session_.historyBrowser().selectedCommand());
}

QVariantMap Application::historyInspection() const {
  const auto &browser = session_.historyBrowser();
  const auto &state = browser.state();
  if (state.selection >= browser.rows().size()) {
    return {};
  }

  const auto &entry = browser.rows()[state.selection];
  const auto *pane = session_.findPane(entry.pane_id);
  const auto tab_name = historyTabName(pane);

  const auto details = HistoryInspectionFacts::derive({.directory = entry.cwd, .provider = entry.provider, .tab = tab_name, .id = entry.id, .pane_id = entry.pane_id, .started_at_ms = entry.started_at_ms, .duration_ns = entry.duration_ns, .exit_code = entry.exit_code, .status = entry.status, .author = entry.author, .origin = entry.origin, .pane_open = pane != nullptr}, history_calendar_);
  QVariantList facts;
  for (const auto &fact : details.lines()) {
    facts.append(QVariantMap{
        {QStringLiteral("label"), toQString(fact.label)},
        {QStringLiteral("text"), toQString(fact.text)},
        {QStringLiteral("color"), QString::fromLatin1(palette_names[static_cast<std::size_t>(fact.color)])},
        {QStringLiteral("mono"), fact.mono},
    });
  }

  return {
      {QStringLiteral("identity"), QString::number(entry.id)},
      {QStringLiteral("facts"), facts},
      {QStringLiteral("heading"), toQString(HistoryInspectionFacts::outputHeading(state.output_phase, state.output_truncated, browser.output().size()).view())},
  };
}

int Application::controlModifier() {
  return static_cast<int>(NativeKeyAdapter::control_modifier);
}

int Application::superModifier() {
  return static_cast<int>(NativeKeyAdapter::super_modifier);
}

void Application::reportHistoryQueryLimit(qulonglong requested_bytes) {
  if (dialog_ != QLatin1StringView("history") || requested_bytes <= HistorySearch::maximum_query_bytes) {
    return;
  }

  session_.reportLimit({.name = "prompt.history_query_bytes", .noun = "bytes", .value = HistorySearch::maximum_query_bytes, .requested = requested_bytes, .route = {}});
  refreshNotifications();
}

void Application::setHistoryFilters(const QVariantMap &filters) {
  applyInteraction([&] {
    auto next = history_filters_;
    if (filters.contains(QStringLiteral("scope"))) {
      next.scope = parseScope(filters.value(QStringLiteral("scope")).toString());
    }

    if (filters.contains(QStringLiteral("author"))) {
      next.author = parseAuthor(filters.value(QStringLiteral("author")).toString());
    }

    if (filters.contains(QStringLiteral("failedOnly"))) {
      next.failed_only = filters.value(QStringLiteral("failedOnly")).toBool();
    }

    history_filters_ = next;
    searchHistory(history_query_);
  });
}

void Application::selectHistoryRow(int row) {
  if (row < 0 || historyLoading()) {
    return;
  }

  applyInteraction([&] {
    session_.selectHistoryRow(static_cast<std::size_t>(row));
  });
}

void Application::selectPresentedHistoryRow(int row, const QString &revision) {
  const auto *presented = presentedHistory(revision);
  if (row < 0 || presented == nullptr) {
    return;
  }

  const HistoryChoice choice{.index = static_cast<std::size_t>(row), .revision = presented->choice.revision};
  if (!session_.historyBrowser().acceptsRow(choice)) {
    return;
  }

  applyInteraction([&] {
    session_.selectHistoryRow(choice.index);
  });
}

void Application::executeHistory(HistoryAction action, const QString &entry_id) {
  if (dialog_ != QLatin1StringView("history") || (historyLoading() && action != HistoryAction::inspect)) {
    return;
  }

  applyInteraction([&] {
    if (action == HistoryAction::older || action == HistoryAction::newer) {
      session_.pageHistory(action == HistoryAction::older ? HistoryPage::older : HistoryPage::newer);
    } else if (action == HistoryAction::inspect) {
      session_.inspectHistory(!session_.historyBrowser().state().inspecting);
    } else {
      const auto &browser = session_.historyBrowser();
      const auto &rows = browser.rows();
      const auto identity = entry_id.isEmpty() && !rows.empty() ? rows[browser.state().selection].id : entry_id.toULongLong();
      if (action == HistoryAction::copy) {
        session_.copyHistory(identity);
        QGuiApplication::clipboard()->setText(toQString(session_.clipboard()));
      } else if (action == HistoryAction::erase) {
        session_.deleteHistory(identity);
      } else if (action == HistoryAction::visit) {
        session_.visitHistory(identity);
        showDialog({});
      }
    }
  });
}

}

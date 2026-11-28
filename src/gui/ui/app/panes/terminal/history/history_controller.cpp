#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "history_controller.hpp"
#include "platform/window.hpp"
#include "ui/kit/models/projection.hpp"
#include "ui/kit/text/utf16_encoding.hpp"
#include <QClipboard>
#include <QGuiApplication>
#include <QStringView>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <string_view>
#include <utility>

import telar.base.text.utf8;
import telar.gui.application;
import telar.gui.foundation.core;
import telar.gui.foundation.forms;
import telar.gui.foundation.system;
import telar.base.ds;

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
      case HistoryScope::global:
        return QStringLiteral("global");
      }

      // A scope outside the enum reads as global.
      return QStringLiteral("global");
    }

    QString authorName(HistoryAuthorFilter author) {
      switch (author) {
      case HistoryAuthorFilter::human:
        return QStringLiteral("human");
      case HistoryAuthorFilter::agent:
        return QStringLiteral("agent");
      case HistoryAuthorFilter::all:
        return QStringLiteral("all");
      }

      // A filter outside the enum reads as all authors.
      return QStringLiteral("all");
    }

    // The pane's commands with those from before it started read as a scope of their own.
    QString scopeName(HistoryScope scope, bool preload) {
      return scope == HistoryScope::pane && preload ? QStringLiteral("session") : scopeName(scope);
    }

    void parseScope(const QString& scope, application::history::HistoryFilters& filters) {
      filters.preload = scope == QStringLiteral("session");
      if (filters.preload) {
        filters.scope = HistoryScope::pane;
        return;
      }

      for (const auto candidate : {HistoryScope::global, HistoryScope::cwd, HistoryScope::workspace, HistoryScope::pane}) {
        if (scopeName(candidate) == scope) {
          filters.scope = candidate;
          return;
        }
      }

      throw EncodingError{"Unknown history scope"};
    }

    // `text` on one line in runs of what `matches` marks and what it does not, from byte `from`,
    // `shown` characters at most.
    // NOLINTNEXTLINE(bugprone-easily-swappable-parameters): where the line starts and how long it is, in the order a substring names them
    QVariantList markedRuns(std::string_view text, const HistoryMatchRanges& matches, std::size_t from, std::size_t shown) {
      QVariantList runs;
      QString run;
      bool run_marked = false;
      std::size_t offset = from;

      for (std::size_t count = 0; offset < text.size() && count < shown; ++count) {
        // A byte that starts no character is one of its own, as the search reads it.
        auto length = std::min(Utf8Scalar::sequenceLength(static_cast<unsigned char>(text[offset])), text.size() - offset);
        if (!Utf8Scalar::tryDecode(text.substr(offset, length))) {
          length = 1;
        }

        const bool marks = matches.covers(offset, length);
        if (marks != run_marked && !run.isEmpty()) {
          runs.append(QVariantMap{{QStringLiteral("text"), run}, {QStringLiteral("marked"), run_marked}});
          run.clear();
        }

        run_marked = marks;
        if (text[offset] == '\n') {
          run.append(QStringLiteral(" ↵ "));
        } else {
          const auto character = text.substr(offset, length);

          run.append(QString::fromUtf8(character.data(), static_cast<qsizetype>(character.size())));
        }

        offset += length;
      }

      if (!run.isEmpty() || runs.isEmpty()) {
        runs.append(QVariantMap{{QStringLiteral("text"), run}, {QStringLiteral("marked"), run_marked}});
      }

      return runs;
    }

    HistoryAuthorFilter parseAuthor(const QString& author) {
      for (const auto candidate : {HistoryAuthorFilter::all, HistoryAuthorFilter::human, HistoryAuthorFilter::agent}) {
        if (authorName(candidate) == author) {
          return candidate;
        }
      }

      throw EncodingError{"Unknown history author filter"};
    }

    // The words the dialog's filter chips show for `value`.
    template <std::size_t Count>
    QString filterLabel(const ds::Array<application::history::HistoryFilterLabels::Choice, Count>& choices, const QString& value) {
      for (const auto& choice : choices) {
        if (QLatin1StringView{choice.value.data(), static_cast<qsizetype>(choice.value.size())} == value) {
          return toQString(choice.text);
        }
      }

      return value;
    }

    // Whether the page holds runs of more than one machine, when the machine tells them apart.
    template <typename Rows>
    bool spansHosts(const Rows& rows) {
      const auto first = std::ranges::find_if(rows, [](const auto& row) {
        return !row.host.empty();
      });

      return first != rows.end() && std::ranges::any_of(rows, [&first](const auto& row) {
        return !row.host.empty() && std::string_view{row.host} != std::string_view{first->host};
      });
    }

    QString phaseName(application::history::HistoryPhase phase) {
      switch (phase) {
      case application::history::HistoryPhase::loading:
        return QStringLiteral("loading");
      case application::history::HistoryPhase::ready:
        return QStringLiteral("ready");
      case application::history::HistoryPhase::failed:
        return QStringLiteral("failed");
      case application::history::HistoryPhase::idle:
        return QStringLiteral("idle");
      }

      // A phase outside the enum reads as idle.
      return QStringLiteral("idle");
    }

  }

  QVariantList HistoryController::marked(const QString& command, const QVariantList& ranges) const { // NOLINT(readability-convert-member-functions-to-static): QML calls it on the instance, and moc has no static invokables
    constexpr std::size_t shown_characters = 240;
    const auto bytes = command.toUtf8();
    const std::string_view text{bytes.constData(), static_cast<std::size_t>(bytes.size())};

    return markedRuns(text, historyMatches(ranges, text.size()), 0, shown_characters);
  }

  QVariantList HistoryController::excerpt(const QString& text, const QVariantList& ranges) const { // NOLINT(readability-convert-member-functions-to-static): QML calls it on the instance, and moc has no static invokables
    // A few words before the match, and enough after it to read it.
    constexpr std::size_t lead_bytes = 24;
    constexpr std::size_t shown_characters = 72;
    const auto bytes = text.toUtf8();
    const std::string_view piece{bytes.constData(), static_cast<std::size_t>(bytes.size())};
    const auto matches = historyMatches(ranges, piece.size());
    auto from = matches.view().empty() ? 0 : matches.view().front().offset - std::min<std::size_t>(matches.view().front().offset, lead_bytes);

    // From the start of a character: a UTF-8 continuation byte is 10xxxxxx.
    constexpr unsigned continuation_mask = 0xC0U;
    constexpr unsigned continuation = 0x80U;

    while (from > 0 && (static_cast<unsigned char>(piece[from]) & continuation_mask) == continuation) {
      --from;
    }

    return markedRuns(piece, matches, from, shown_characters);
  }

  HistoryController::HistoryController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {
    // At most one search is in flight and the newest typed waits for it, so typing never queues
    // work and never waits: the runtime's index answers a keystroke at once. The keys of one
    // event batch still go as one search.
    constexpr int debounce_ms = 0;

    constexpr int age_ms = 30'000;

    search_timer_.setSingleShot(true);
    search_timer_.setInterval(debounce_ms);
    connect(&search_timer_, &QTimer::timeout, this, &HistoryController::query);
    age_timer_.setInterval(age_ms);
    connect(&age_timer_, &QTimer::timeout, this, &HistoryController::age);
    // Long enough to read the notice and reach the key, as mail clients give.
    constexpr int undo_ms = 5'000;

    undo_timer_.setSingleShot(true);
    undo_timer_.setInterval(undo_ms);
    connect(&undo_timer_, &QTimer::timeout, this, &HistoryController::commitRemoval);
  }

  void HistoryController::open() {
    auto& session = store_.sessionMut();

    filters_ = {.author = session.configuration.history.show_agent_commands ? HistoryAuthorFilter::all : HistoryAuthorFilter::human};
    application::history::inspect(session, false);
    application::history::clearMarks(session);
    // At the prompt line, the search starts from the command being written.
    QString seed;

    const auto line_pane = store_.dialog().line_search_pane;
    if (const auto line = line_pane == 0 ? ds::none : application::prompt::line(session, line_pane)) {
      seed = toQString(line->text());
      seed.replace(QLatin1Char('\n'), QLatin1Char(' '));
    }

    search(seed);
    age_timer_.start();
  }

  void HistoryController::sendQueued() {
    if (search_queued_ && application::history::view(store_.session()).state().load != application::history::HistoryLoad::search) {
      query();
    }
  }

  void HistoryController::commitRemoval() {
    undo_timer_.stop();
    if (application::history::view(store_.session()).hidden() == 0) {
      return;
    }

    interact([&] {
      application::history::commit(store_.sessionMut());
    });
  }

  void HistoryController::forget() {
    // The delete waiting goes to the session it was asked of, before it is forgotten, and the
    // runtime no longer tells the closed panel of changes.
    // Stopping the watch is a flag of this session, not an interaction: committing one here, while
    // the dialog that closes the panel is still being shown, would refresh every controller
    // before that dialog changed, and one that asks to close it would ask again.
    commitRemoval();
    application::history::watch(store_.sessionMut(), false);

    search_timer_.stop();
    age_timer_.stop();
    pending_submit_.reset();
    pending_moves_ = 0;
    search_queued_ = false;
    rows_.reconcile({});
    records_.clear();
    synchronized_.reset();
    rows_version_ = 0;
    directory_source_.clear();
    directory_value_.clear();
  }

  void HistoryController::setMetrics(const application::history::HistoryModalMetrics& metrics) {
    metrics_ = metrics;
    emit changed();
  }

  void HistoryController::fail(const std::exception& error) {
    if (!isOpen()) {
      emit failed(QString::fromUtf8(error.what()));

      return;
    }

    application::history::report(store_.sessionMut(), error.what());
    synchronize();
  }

  QAbstractItemModel* HistoryController::rows() noexcept {
    return &rows_;
  }

  // QML reads loading in the same snapshot as state, rows and the rest; actions check busy().
  bool HistoryController::loading() const {
    return synchronized_ ? synchronized_->loading : busy();
  }

  bool HistoryController::queryPending() const {
    return search_timer_.isActive() || search_queued_ || application::history::view(store_.session()).state().load == application::history::HistoryLoad::search;
  }

  bool HistoryController::busy() const {
    return search_timer_.isActive() || search_queued_ || application::history::loading(store_.session());
  }

  bool HistoryController::isOpen() const noexcept {
    return store_.dialog().kind == Store::Dialog::history;
  }

  void HistoryController::settlePending() {
    if (!isOpen() || busy()) {
      return;
    }

    if (pending_moves_ != 0) {
      const auto moves = std::exchange(pending_moves_, 0);

      interact([&] {
        step(moves);
      });
    }

    // A move that loads another page waits for it too.
    if (!pending_submit_ || busy()) {
      return;
    }

    const bool alternate = *pending_submit_;
    const auto browser = application::history::view(store_.session());
    const auto& rows = browser.rows();

    pending_submit_.reset();
    if (browser.state().selection < rows.size()) {
      submit(rows[browser.state().selection].id, alternate);
    }
  }

  void HistoryController::synchronize() {
    // What waited for the rows runs once this flush is done, so that none of it reenters the
    // flush: closing the panel ends the time to take a delete back, a query typed while the one
    // before was in flight goes, and the moves and Enter made while the rows loaded apply.
    if (!isOpen() && undo_timer_.isActive()) {
      undo_timer_.stop();
      QMetaObject::invokeMethod(this, &HistoryController::commitRemoval, Qt::QueuedConnection);
    }

    if (search_queued_ && application::history::view(store_.session()).state().load != application::history::HistoryLoad::search) {
      QMetaObject::invokeMethod(this, &HistoryController::sendQueued, Qt::QueuedConnection);
    }

    if ((pending_submit_ || pending_moves_ != 0) && !busy()) {
      QMetaObject::invokeMethod(this, &HistoryController::settlePending, Qt::QueuedConnection);
    }

    auto next = inputs();
    if (synchronized_ == next) {
      return;
    }

    const auto browser = application::history::view(store_.session());
    if (rows_version_ != browser.rowsVersion()) {
      buildRows();
      rows_version_ = browser.rowsVersion();
    }

    synchronized_ = std::move(next);
    state_ = buildState();
    inspection_ = buildInspection();
    command_ = toQString(browser.selectedCommand());
    output_ = toQString(browser.output());
    emit changed();
  }

  HistoryController::Inputs HistoryController::inputs() {
    const auto& session = store_.session();
    const auto browser = application::history::view(session);
    const auto open = isOpen();
    const auto selection = browser.state().selection;
    const auto* pane = open && selection < browser.rows().size() ? session.findPane(browser.rows()[selection].pane_id) : nullptr;
    Inputs inputs{
        .open = open,
        .generation = store_.dialog().generation,
        .view_version = browser.viewVersion(),
        .search_version = search_version_,
        .configuration = session.viewVersion().configuration,
        .loading = busy(),
        .pane_open = pane != nullptr,
        .scope_value = open ? scopeValue() : QString{},
    };

    inputs.tab_name.append(tabName(pane));

    return inputs;
  }

  void HistoryController::buildRows() {
    using Labels = application::history::HistoryLabels;
    const auto& rows = application::history::view(store_.session()).rows();
    const auto sampled = system::WallClock::sample();
    const auto today = Labels::localDay(sampled.now_ms, sampled.utc_offset_min);

    // A record of the command a row showed before is the same while its outcome and the words
    // its age is told in stay: keystrokes and refreshes rebuild only the rows that changed, and
    // the model announces only those.
    if (sampled.utc_offset_min != calendar_.utc_offset_min) {
      records_.clear();
    }

    calendar_ = sampled;
    QHash<std::uint64_t, CachedRecord> next;
    QList<QVariantMap> records;
    std::size_t kept = 0;

    next.reserve(static_cast<qsizetype>(rows.size()));
    records.reserve(static_cast<qsizetype>(rows.size()));
    for (std::size_t index = 0; index < rows.size(); ++index) {
      const auto& entry = rows[index];
      const auto day = Labels::localDay(entry.started_at_ms, sampled.utc_offset_min);
      const auto group_ends = index + 1 == rows.size() || day != Labels::localDay(rows[index + 1].started_at_ms, sampled.utc_offset_min);
      CachedRecord cached{.status = entry.status, .duration_ns = entry.duration_ns, .exit_code = entry.exit_code, .age = Labels::ageAt(entry.started_at_ms, sampled), .date = entry.started_at_ms >= 0 ? Labels::dateLabel(entry.started_at_ms, sampled) : Labels::Text{}, .today = today, .ranges = entry.ranges, .excerpt_ranges = entry.excerpt_ranges, .excerpt = std::hash<std::string_view>{}(entry.excerpt), .neighbour = entry.neighbour};
      const auto found = records_.constFind(entry.id);

      kept += found != records_.cend() ? 1 : 0;
      if (found != records_.cend() && found->same(cached)) {
        cached.record = found->record;
      } else {
        cached.record = historyRecord(entry, sampled);
      }

      if (cached.record.value(QStringLiteral("groupEnds")).toBool() != group_ends || !cached.record.contains(QStringLiteral("groupEnds"))) {
        cached.record.insert(QStringLiteral("groupEnds"), group_ends);
      }

      records.append(cached.record);
      next.insert(entry.id, std::move(cached));
    }

    const auto shown = static_cast<std::size_t>(records_.size());

    records_ = std::move(next);
    // Rows that show mostly the commands shown before, as a refresh does, follow their commands:
    // one arriving on top is inserted, one leaving is removed, and every other row keeps its
    // delegate, its selection and its place on screen. Rows of another search show other
    // commands: they take the delegates in place, which rebinds them instead of making new ones.
    if (2 * kept >= std::max(shown, rows.size()) && kept != 0) {
      rows_.reconcile(std::move(records));
    } else {
      rows_.replaceRows(std::move(records));
    }
  }

  std::string_view HistoryController::tabName(const application::Pane<Memory>* pane) const {
    const auto& session = store_.session();

    if (pane != nullptr) {
      for (const auto& tab : session.tabs) {
        if (sameTab(tab->location, pane->location)) {
          return tab->label.empty() ? application::tabApplicationName(*tab, session.findPane(tab->focused_pane)) : std::string_view{tab->label};
        }
      }
    }

    return {};
  }

  QString HistoryController::scopeValue() {
    const auto& session = store_.session();
    if (application::history::view(session).scope() == HistoryScope::workspace) {
      if (const auto typed = filters_.chips.value(application::history::HistoryFilterKey::workspace)) {
        return toQString(*typed);
      }

      const auto* active = session.activeTab();
      if (active == nullptr || active->location.workspace.kind != WorkspaceLocation::Kind::workspace) {
        return {};
      }

      const auto* const current = std::ranges::find_if(session.workspaces(), [&](const auto& workspace) {
        return sameWorkspace(workspace.location, active->location.workspace);
      });

      return current == session.workspaces().end() ? QString{} : toQString(current->name);
    }

    if (application::history::view(session).scope() != HistoryScope::cwd) {
      return {};
    }

    // A typed directory is the scope's, as typed.
    if (const auto typed = filters_.chips.value(application::history::HistoryFilterKey::cwd)) {
      return toQString(*typed);
    }

    const auto* pane = session.focusedPane();
    if (pane == nullptr) {
      return {};
    }

    const QByteArrayView source{pane->cwd.data(), static_cast<qsizetype>(pane->cwd.size())};
    if (QByteArrayView{directory_source_} != source) {
      const auto compact = application::history::HistoryPath::compact(std::string_view{pane->cwd.data(), pane->cwd.size()});
      auto value = toQString(compact.view());

      directory_source_.assign(source);
      directory_value_ = std::move(value);
    }

    return directory_value_;
  }

  // Before the first synchronization, and after the session it showed went away, QML still reads
  // the live state.
  QVariantMap HistoryController::state() const {
    return synchronized_ ? state_ : buildState();
  }

  QString HistoryController::output() const {
    return synchronized_ ? output_ : toQString(application::history::view(store_.session()).output());
  }

  QString HistoryController::command() const {
    return synchronized_ ? command_ : toQString(application::history::view(store_.session()).selectedCommand());
  }

  QVariantMap HistoryController::inspection() const {
    return synchronized_ ? inspection_ : buildInspection();
  }

  QVariantMap HistoryController::buildState() const {
    const auto& session = store_.session();
    const auto browser = application::history::view(session);
    const auto& state = browser.state();
    const auto& rows = browser.rows();
    const bool selected_detail = state.selection < rows.size() && rows[state.selection].id == state.command_id;
    QVariantList chips;
    QVariantList marks;

    for (const auto& chip : filters_.chips.view()) {
      auto label = toQString(application::history::HistoryFilterKeys::name(chip.key));

      label.append(QLatin1Char(':'));
      label.append(toQString(chip.value.view()));
      chips.append(QVariantMap{
          {QStringLiteral("label"), label},
          {QStringLiteral("applied"), application::history::HistoryFilterKeys::applied(chip)},
          {QStringLiteral("key"), toQString(application::history::HistoryFilterKeys::name(chip.key))},
      });
    }

    for (std::size_t index = 0; index < browser.markCount(); ++index) {
      marks.append(QString::number(browser.markedId(index)));
    }

    return {
        {QStringLiteral("generation"), QString::number(store_.dialog().generation)},
        {QStringLiteral("selectedId"), state.selection < rows.size() ? QString::number(rows[state.selection].id) : QString{}},
        {QStringLiteral("phase"), phaseName(state.phase)},
        {QStringLiteral("hasPage"), state.has_page},
        {QStringLiteral("revision"), QString::number(browser.revision())},
        {QStringLiteral("scope"), scopeName(filters_.scope, filters_.preload)},
        {QStringLiteral("effectiveScope"), scopeName(browser.scope(), browser.preloads())},
        {QStringLiteral("scopeValue"), synchronized_ ? synchronized_->scope_value : QString{}},
        {QStringLiteral("author"), authorName(filters_.author)},
        {QStringLiteral("scopeLabel"), filterLabel(application::history::HistoryFilterLabels::scopes, scopeName(browser.scope(), browser.preloads()))},
        {QStringLiteral("searchesOutput"), browser.searchesOutput()},
        {QStringLiteral("raw"), filters_.chips.value(application::history::HistoryFilterKey::raw).hasValue()},
        {QStringLiteral("showHost"), session.configuration.history.show_host && spansHosts(rows)},
        {QStringLiteral("authorLabel"), filterLabel(application::history::HistoryFilterLabels::authors, authorName(filters_.author))},
        {QStringLiteral("failedOnly"), filters_.failed_only},
        {QStringLiteral("grouped"), query_.isEmpty()},
        {QStringLiteral("query"), query_},
        {QStringLiteral("chips"), chips},
        {QStringLiteral("pins"), shownPins()},

        {QStringLiteral("marks"), marks},
        {QStringLiteral("hidden"), browser.hidden() != 0},
        {QStringLiteral("hiddenCommand"), toQString(browser.hiddenCommand())},
        {QStringLiteral("undoKey"), platform::usesCommandKey() ? QStringLiteral("⌘Z") : QStringLiteral("Ctrl+Z")},
        {QStringLiteral("editorText"), query_},
        {QStringLiteral("maximumQueryBytes"), static_cast<int>(application::history::HistorySearch::maximum_query_bytes)},
        {QStringLiteral("inspectionKey"), platform::usesCommandKey() ? QStringLiteral("⌃O") : QStringLiteral("Ctrl+O")},
        {QStringLiteral("macStyle"), platform::usesCommandKey()},
        {QStringLiteral("paneOpen"), state.selection < rows.size() && session.findPane(rows[state.selection].pane_id) != nullptr},
        {QStringLiteral("commandLoaded"), state.selection < rows.size() && (rows[state.selection].command_complete || (selected_detail && state.command_phase == application::history::HistoryPhase::ready))},
        {QStringLiteral("canOlder"), browser.canPage(application::history::HistoryPage::older)},
        {QStringLiteral("hasMore"), state.has_more},
        {QStringLiteral("match"), toQString(application::history::HistoryModes::name(browser.match()))},
        {QStringLiteral("canNewer"), browser.canPage(application::history::HistoryPage::newer)},
        {QStringLiteral("offset"), static_cast<qulonglong>(state.page_offset)},
        {QStringLiteral("selection"), static_cast<int>(state.selection)},
        {QStringLiteral("count"), static_cast<int>(browser.rows().size())},
        {QStringLiteral("canSubmit"), browser.canSubmit()},
        {QStringLiteral("commandPhase"), phaseName(selected_detail ? state.command_phase : application::history::HistoryPhase::idle)},
        {QStringLiteral("enterRuns"), session.configuration.history.enter_runs},
        {QStringLiteral("showDuration"), session.configuration.history.show_duration},
        {QStringLiteral("showExit"), session.configuration.history.show_exit},
        {QStringLiteral("showDirectory"), session.configuration.history.show_directory},
        {QStringLiteral("relativeTime"), session.configuration.history.relative_time},
        {QStringLiteral("inspecting"), state.inspecting},
        {QStringLiteral("outputPhase"), phaseName(state.output_phase)},
        {QStringLiteral("outputTruncated"), state.output_truncated},
        {QStringLiteral("deleting"), browser.deleting()},
        {QStringLiteral("error"), toQString(browser.error())},
    };
  }

  QVariantMap HistoryController::buildInspection() const {
    const auto& session = store_.session();
    const auto browser = application::history::view(session);
    const auto& state = browser.state();
    if (state.selection >= browser.rows().size()) {
      return {};
    }

    const auto& entry = browser.rows()[state.selection];
    const auto* pane = session.findPane(entry.pane_id);
    const auto tab_name = tabName(pane);

    const auto details = application::history::HistoryInspectionFacts::derive({.directory = entry.cwd, .provider = entry.provider, .tab = tab_name, .id = entry.id, .pane_id = entry.pane_id, .started_at_ms = entry.started_at_ms, .duration_ns = entry.duration_ns, .exit_code = entry.exit_code, .status = entry.status, .author = entry.author, .origin = entry.origin, .pane_open = pane != nullptr}, calendar_);
    QVariantList facts;
    const auto append = [&facts](const application::history::HistoryInspectionLine& fact) {
      facts.append(QVariantMap{
          {QStringLiteral("label"), toQString(fact.label)},
          {QStringLiteral("text"), toQString(fact.text)},
          {QStringLiteral("color"), QString::fromLatin1(palette_names[static_cast<std::size_t>(fact.color)])},
          {QStringLiteral("mono"), fact.mono},
      });
    };

    for (const auto& fact : details.lines()) {
      append(fact);
    }

    // The command's runs, its exact text read anywhere, and the commands run around this one in
    // its pane, once the runtime answered.
    if (state.runs_phase == application::history::HistoryPhase::ready) {
      const auto runs = application::history::HistoryRunFacts::derive(browser.runStats(), calendar_);

      for (const auto& fact : runs.lines()) {
        if (!fact.text.empty()) {
          append(fact);
        }
      }
    }

    // In the order they ran: the listing reads newest first.
    for (auto index = browser.contextCount(); index-- > 0;) {
      const auto around = browser.contextAt(index);

      append({.kind = application::history::HistoryInspectionLine::Kind::fact, .text = around.command, .label = around.newer ? "Then" : "Before", .color = PaletteRole::subtext0, .mono = true});
    }

    return {
        {QStringLiteral("identity"), QString::number(entry.id)},
        {QStringLiteral("facts"), facts},
        {QStringLiteral("heading"), toQString(application::history::HistoryInspectionFacts::outputHeading(state.output_phase, state.output_truncated, browser.output().size()).view())},
    };
  }

  void HistoryController::search(const QString& query) {
    const auto measured = Utf16Prefix::fit(QStringView{query}, application::history::HistorySearch::maximum_query_bytes, utf16Encoding());

    query_ = query.first(static_cast<qsizetype>(measured.units));
    if (!query_.isValidUtf16()) {
      query_ = QString::fromUtf8(query_.toUtf8());
    }

    // A filter typed as a word, `cwd:src `, leaves the query for a chip.
    const auto typed = query_.toUtf8();
    application::history::HistoryTyping::Query rest;

    if (application::history::HistoryTyping::absorb({typed.constData(), static_cast<std::size_t>(typed.size())}, filters_, rest)) {
      query_ = toQString(rest.view());
    }

    // Typing again takes back an Enter and the moves that waited for the search.
    pending_submit_.reset();
    pending_moves_ = 0;
    search_timer_.start();
    ++search_version_;
    synchronize();

    if (measured.bytes < measured.requested_bytes) {
      reportQueryLimit(static_cast<qulonglong>(measured.requested_bytes));
    }
  }

  void HistoryController::age() {
    if (!isOpen()) {
      age_timer_.stop();
      return;
    }

    if (busy()) {
      return;
    }

    // Ages are told anew at once. A runtime that tells of each change brings what changed; for
    // one that does not, the newest page is read again too, which brings the commands recorded
    // since it loaded, and on a later page a row still running is, which brings its duration and
    // end. The rows stay usable while they are read.
    buildRows();
    state_ = buildState();
    inspection_ = buildInspection();
    emit changed();

    const auto browser = application::history::view(store_.session());
    if (browser.watching()) {
      return;
    }

    const bool running = std::ranges::any_of(browser.rows(), [](const auto& row) {
      return row.status == HistoryStatus::running;
    });

    if (running || browser.state().page_offset == 0) {
      interact([&] {
        application::history::refresh(store_.sessionMut());
      });
    }
  }

  void HistoryController::query() {
    // The search in flight answers first; the newest query typed replaces any that waited.
    if (application::history::view(store_.session()).state().load == application::history::HistoryLoad::search) {
      search_queued_ = true;
      return;
    }

    search_queued_ = false;
    try {
      const auto query = query_.toUtf8();

      application::history::search(store_.sessionMut(), std::string_view{query.constData(), static_cast<std::size_t>(query.size())}, filters_, system::WallClock::sample());
    } catch (const std::exception& error) {
      fail(error);
    }

    synchronize();
  }

  void HistoryController::applyFilter(const QString& word) {
    const auto typed = (word + QLatin1Char(' ')).toUtf8();
    auto next = filters_;
    application::history::HistoryTyping::Query rest;

    if (application::history::HistoryTyping::absorb({typed.constData(), static_cast<std::size_t>(typed.size())}, next, rest) && rest.view().empty()) {
      filters_ = next;

      // search() replaces the query it is given.
      const auto query = query_;

      search(query);
    }
  }

  void HistoryController::toggle(const QString& name) {
    using Key = application::history::HistoryFilterKey;

    if (name != QStringLiteral("sort") && name != QStringLiteral("output") && name != QStringLiteral("raw") && name != QStringLiteral("mode")) {
      return;
    }

    auto key = Key::raw;

    if (name == QStringLiteral("sort")) {
      key = Key::sort;
    } else if (name == QStringLiteral("output")) {
      key = Key::output;
    } else if (name == QStringLiteral("mode")) {
      key = Key::mode;
    }

    const auto chips = filters_.chips.view();
    std::size_t index = 0;

    while (index < chips.size() && chips[index].key != key) {
      ++index;
    }

    auto next = filters_;

    if (key == Key::sort) {
      // Without a chip the runtime ranks a query typed and lists by time without one.
      const bool ranked = index < chips.size() ? chips[index].value.view() == "rank" : !query_.isEmpty();

      static_cast<void>(next.chips.set(key, ranked ? "time" : "rank"));
    } else if (key == Key::mode) {
      // From the mode the search matches with now: the chip's, else the configuration's.
      const auto mode = application::history::HistoryModes::next(application::history::view(store_.session()).match());

      static_cast<void>(next.chips.set(key, application::history::HistoryModes::name(mode)));
    } else if (index < chips.size()) {
      static_cast<void>(next.chips.remove(index));
    } else {
      static_cast<void>(next.chips.set(key, key == Key::output ? std::string_view{"output"} : application::history::HistoryFilterKeys::raw_neighbours));
    }

    filters_ = next;

    // search() replaces the query it is given.
    const auto query = query_;

    search(query);
  }

  void HistoryController::removeChip(int index) {
    const auto count = filters_.chips.view().size();
    if (count == 0) {
      return;
    }

    if (filters_.chips.remove(index < 0 ? count - 1 : static_cast<std::size_t>(index))) {
      // search() replaces the query it is given.
      const auto query = query_;

      search(query);
    }
  }

  QString HistoryController::completeFilter(const QString& text) const { // NOLINT(readability-convert-member-functions-to-static): QML calls it on the instance, and moc has no static invokables
    const auto typed = text.toUtf8();
    const auto completed = application::history::HistoryTyping::complete({typed.constData(), static_cast<std::size_t>(typed.size())});

    return completed ? toQString(completed->view()) : QString{};
  }

  QVariantList HistoryController::shownPins() const {
    constexpr std::size_t reach = 9;
    const auto query = query_.toUtf8();
    const std::string_view wanted{query.constData(), static_cast<std::size_t>(query.size())};
    QVariantList shown;

    for (std::size_t index = 0; index < pins_.count() && std::cmp_less(shown.size(), reach); ++index) {
      const auto command = pins_.at(index);
      if (!wanted.empty() && HistoryMatchRanges::find(command, wanted).view().empty()) {
        continue;
      }

      auto line = toQString(command);

      line.replace(QLatin1Char('\n'), QStringLiteral(" ↵ "));
      shown.append(QVariantMap{{QStringLiteral("text"), line}, {QStringLiteral("index"), static_cast<int>(index)}});
    }

    return shown;
  }

  void HistoryController::usePin(int index, bool alternate) {
    const auto shown = shownPins();
    if (!isOpen() || index < 0 || index >= shown.size()) {
      return;
    }

    const auto pin = static_cast<std::size_t>(shown[index].toMap().value(QStringLiteral("index")).toInt());

    interact([&] {
      application::history::pasteCommand(store_.sessionMut(), pins_.at(pin), alternate);
      emit submitted();
      emit closeRequested();
    });
  }

  void HistoryController::quickUse(int row) {
    if (!isOpen() || busy()) {
      return;
    }

    const auto& entries = application::history::view(store_.session()).rows();
    if (row >= 0 && std::cmp_less(row, entries.size())) {
      submit(entries[static_cast<std::size_t>(row)].id, false);
    }
  }

  void HistoryController::reportQueryLimit(qulonglong requested_bytes) {
    if (!isOpen() || requested_bytes <= application::history::HistorySearch::maximum_query_bytes) {
      return;
    }

    application::notifications::reportLimit(store_.sessionMut(), {.name = "prompt.history_query_bytes", .noun = "bytes", .value = application::history::HistorySearch::maximum_query_bytes, .requested = requested_bytes, .route = {}});
    store_.commit();
  }

  void HistoryController::setFilters(const QVariantMap& filters) {
    interact([&] {
      auto next = filters_;

      if (filters.contains(QStringLiteral("scope"))) {
        parseScope(filters.value(QStringLiteral("scope")).toString(), next);
      }

      if (filters.contains(QStringLiteral("author"))) {
        next.author = parseAuthor(filters.value(QStringLiteral("author")).toString());
      }

      if (filters.contains(QStringLiteral("failedOnly"))) {
        next.failed_only = filters.value(QStringLiteral("failedOnly")).toBool();
      }

      filters_ = next;

      // search() replaces the query it is given.
      const auto query = query_;

      search(query);
    });
  }

  void HistoryController::select(int row) {
    pending_submit_.reset();
    if (row < 0 || busy()) {
      return;
    }

    interact([&] {
      application::history::select(store_.sessionMut(), static_cast<std::size_t>(row));
    });
  }

  void HistoryController::selectPresented(int row, const QString& revision) {
    const auto* shown = presented(revision);
    if (row < 0 || shown == nullptr) {
      return;
    }

    const application::history::HistoryChoice choice{.index = static_cast<std::size_t>(row), .revision = shown->choice.revision};
    if (!application::history::view(store_.session()).acceptsRow(choice)) {
      return;
    }

    interact([&] {
      application::history::select(store_.sessionMut(), choice.index);
    });
  }

  void HistoryController::execute(Action action, const QString& entry_id) {
    if (action == Action::older || action == Action::newer) {
      pending_submit_.reset();
    }

    // The rows shown stay usable while others load: copying, deleting or visiting acts on the
    // command the person sees; a page waits for the one loading.
    if (!isOpen() || (busy() && (action == Action::older || action == Action::newer))) {
      return;
    }

    interact([&] {
      auto& session = store_.sessionMut();

      if (action == Action::older || action == Action::newer) {
        application::history::page(session, action == Action::older ? application::history::HistoryPage::older : application::history::HistoryPage::newer);
      } else if (action == Action::undo) {
        undo_timer_.stop();
        application::history::undo(session);
      } else if (action == Action::inspect) {
        application::history::inspect(session, !application::history::view(session).state().inspecting);
      } else {
        const auto browser = application::history::view(session);
        const auto& rows = browser.rows();
        const auto identity = entry_id.isEmpty() && browser.state().selection < rows.size() ? rows[browser.state().selection].id : entry_id.toULongLong();
        if (identity != 0) {
          act(action, identity);
        }
      }
    });
  }

  void HistoryController::act(Action action, std::uint64_t identity) {
    auto& session = store_.sessionMut();

    switch (action) {
    case Action::copy:
      application::history::copy(session, identity);
      QGuiApplication::clipboard()->setText(toQString(session.clipboard()));
      break;
    case Action::erase:
      // The row leaves now and its delete waits for the undo the notice offers.
      application::history::hide(session, identity);
      undo_timer_.start();
      break;
    case Action::visit:
      application::history::visit(session, identity);
      emit closeRequested();
      break;
    case Action::mark:
      application::history::mark(session, identity);
      break;
    case Action::enter:
      application::history::enter(session, identity);
      emit submitted();
      emit closeRequested();
      break;
    case Action::open:
      application::history::open(session, identity);
      emit closeRequested();
      break;
    case Action::pin:
      static_cast<void>(pins_.toggle(application::history::view(session).command(identity)));
      savePins();
      ++search_version_;
      break;
    case Action::inspect:
    case Action::older:
    case Action::newer:
    case Action::undo:
      break;
    }
  }

  void HistoryController::submit(std::uint64_t entry_id, bool alternate) {
    if (!isOpen()) {
      return;
    }

    interact([&] {
      if (queryPending()) {
        throw EncodingError{"History search is still loading"};
      }

      auto& session = store_.sessionMut();

      // Commands marked go together, in place of the one selected.
      if (application::history::view(session).markCount() != 0) {
        application::history::pasteMarked(session, alternate);
      } else {
        application::history::paste(session, entry_id, alternate);
      }

      emit submitted();
      emit closeRequested();
    });
  }

  void HistoryController::use(int row, bool alternate) {
    if (!isOpen()) {
      return;
    }

    // The rows shown are of an older query, or a page replaces them: the search runs now, and
    // the row selected once its page arrives, as fzf runs its best match. A refresh reads the
    // rows shown anew, so Enter runs the row selected at once.
    if (busy()) {
      pending_submit_ = alternate;
      if (search_timer_.isActive()) {
        search_timer_.stop();
        query();
      }

      return;
    }

    const auto& entries = application::history::view(store_.session()).rows();
    if (row < 0 || static_cast<std::size_t>(row) >= entries.size()) {
      return;
    }

    submit(entries[static_cast<std::size_t>(row)].id, alternate);
  }

  void HistoryController::usePresented(const QString& revision, bool alternate) {
    const auto* shown = presented(revision);
    if (shown == nullptr || shown->enter_runs != store_.session().configuration.history.enter_runs) {
      return;
    }

    const auto browser = application::history::view(store_.session());
    if (!browser.accepts(shown->choice)) {
      return;
    }

    submit(browser.rows()[shown->choice.index].id, alternate);
  }

  const HistoryController::Presented* HistoryController::presented(const QString& revision) const {
    if (!isOpen() || busy() || !presented_) {
      return nullptr;
    }

    const auto& shown = *presented_;
    if (shown.dialog_generation != store_.dialog().generation) {
      return nullptr;
    }

    bool valid_revision = false;
    const auto requested_revision = revision.toULongLong(&valid_revision);

    return valid_revision && shown.choice.revision == requested_revision ? &shown : nullptr;
  }

}

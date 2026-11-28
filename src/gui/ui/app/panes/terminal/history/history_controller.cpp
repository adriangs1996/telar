module telar.gui.ui.app.panes.terminal.history;

import std;
import telar.gui.qt;
import telar.gui.qt.platform;
import telar.gui.ui.kit.models;
import telar.gui.ui.kit.text;
import telar.base.text.utf8;
import telar.gui.application;
import telar.base.ds;
import telar.gui.foundation.system;
import telar.wire.vocabulary;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  namespace {

    // The query without the ! that leads it and the blanks after, which ask for failed commands.
    QString withoutFailedMark(const QString& query) {
      if (!query.startsWith(QLatin1Char('!'))) {
        return query;
      }

      qsizetype start = 1;

      while (start < query.size() && query[start] == QLatin1Char(' ')) {
        ++start;
      }

      return query.mid(start);
    }

    QString scopeName(HistoryScope scope) {
      switch (scope) {
      case HistoryScope::cwd:
        return u"cwd"_s;
      case HistoryScope::workspace:
        return u"workspace"_s;
      case HistoryScope::pane:
        return u"pane"_s;
      case HistoryScope::global:
        return u"global"_s;
      }

      // A scope outside the enum reads as global.
      return u"global"_s;
    }

    QString authorName(HistoryAuthorFilter author) {
      switch (author) {
      case HistoryAuthorFilter::human:
        return u"human"_s;
      case HistoryAuthorFilter::agent:
        return u"agent"_s;
      case HistoryAuthorFilter::all:
        return u"all"_s;
      }

      // A filter outside the enum reads as all authors.
      return u"all"_s;
    }

    HistoryScope parseScope(const QString& scope) {
      for (const auto candidate : {HistoryScope::global, HistoryScope::cwd, HistoryScope::workspace, HistoryScope::pane}) {
        if (scopeName(candidate) == scope) {
          return candidate;
        }
      }

      throw EncodingError{"Unknown history scope"};
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

    QString phaseName(application::history::HistoryPhase phase) {
      switch (phase) {
      case application::history::HistoryPhase::loading:
        return u"loading"_s;
      case application::history::HistoryPhase::ready:
        return u"ready"_s;
      case application::history::HistoryPhase::failed:
        return u"failed"_s;
      case application::history::HistoryPhase::idle:
        return u"idle"_s;
      }

      // A phase outside the enum reads as idle.
      return u"idle"_s;
    }

  }

  HistoryController::HistoryController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {
    constexpr int debounce_ms = 60;

    constexpr int age_ms = 30'000;

    search_timer_.setSingleShot(true);
    search_timer_.setInterval(debounce_ms);
    connect(&search_timer_, &QTimer::timeout, this, &HistoryController::query);
    age_timer_.setInterval(age_ms);
    connect(&age_timer_, &QTimer::timeout, this, &HistoryController::age);
  }

  void HistoryController::open() {
    auto& session = store_.sessionMut();

    filters_ = {.author = session.configuration.history.show_agent_commands ? HistoryAuthorFilter::all : HistoryAuthorFilter::human};
    application::history::inspect(session, false);
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

  void HistoryController::forget() {
    search_timer_.stop();
    age_timer_.stop();
    pending_submit_.reset();
    rows_.reconcile({});
    synchronized_.reset();
    rows_version_ = 0;
    directory_source_.clear();
    directory_value_.clear();
  }

  void HistoryController::setMetrics(const application::history::HistoryModalMetrics& metrics) {
    metrics_ = metrics;
    changed();
  }

  void HistoryController::fail(const std::exception& error) {
    if (!isOpen()) {
      failed(QString::fromUtf8(error.what()));

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

  bool HistoryController::busy() const {
    return search_timer_.isActive() || application::history::loading(store_.session());
  }

  bool HistoryController::isOpen() const noexcept {
    return store_.dialog().kind == Store::Dialog::history;
  }

  void HistoryController::synchronize() {
    if (pending_submit_ && !busy()) {
      const bool alternate = *pending_submit_;
      const auto& rows = application::history::view(store_.session()).rows();

      pending_submit_.reset();
      if (!rows.empty()) {
        submit(rows.front().id, alternate);
        return;
      }
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
    changed();
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
    const auto& rows = application::history::view(store_.session()).rows();
    const auto sampled = system::WallClock::sample();

    calendar_ = sampled;
    QList<QVariantMap> records;

    records.reserve(static_cast<qsizetype>(rows.size()));
    for (std::size_t index = 0; index < rows.size(); ++index) {
      const auto& entry = rows[index];
      auto record = historyRecord(entry, sampled);
      const auto day = application::history::HistoryLabels::localDay(entry.started_at_ms, sampled.utc_offset_min);
      const auto group_ends = index + 1 == rows.size() || day != application::history::HistoryLabels::localDay(rows[index + 1].started_at_ms, sampled.utc_offset_min);

      record.insert(u"groupEnds"_s, group_ends);
      records.append(std::move(record));
    }

    rows_.replaceRows(std::move(records));
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
    const auto query = query_.toUtf8();
    const auto parsed = application::history::HistorySearch::parse({query.constData(), static_cast<std::size_t>(query.size())}, filters_.failed_only);

    return {
        {u"generation"_s, QString::number(store_.dialog().generation)},
        {u"selectedId"_s, state.selection < rows.size() ? QString::number(rows[state.selection].id) : QString{}},
        {u"phase"_s, phaseName(state.phase)},
        {u"hasPage"_s, state.has_page},
        {u"revision"_s, QString::number(browser.revision())},
        {u"scope"_s, scopeName(filters_.scope)},
        {u"effectiveScope"_s, scopeName(browser.scope())},
        {u"scopeValue"_s, synchronized_ ? synchronized_->scope_value : QString{}},
        {u"author"_s, authorName(filters_.author)},
        {u"scopeLabel"_s, filterLabel(application::history::HistoryFilterLabels::scopes, scopeName(browser.scope()))},
        {u"authorLabel"_s, filterLabel(application::history::HistoryFilterLabels::authors, authorName(filters_.author))},
        {u"failedOnly"_s, parsed.failed_only},
        {u"grouped"_s, parsed.query.empty()},
        {u"query"_s, toQString(parsed.query)},
        {u"editorText"_s, query_},
        {u"maximumQueryBytes"_s, static_cast<int>(application::history::HistorySearch::maximum_query_bytes)},
        {u"inspectionKey"_s, platform::usesCommandKey() ? u"⌃O"_s : u"Ctrl+O"_s},
        {u"macStyle"_s, platform::usesCommandKey()},
        {u"paneOpen"_s, state.selection < rows.size() && session.findPane(rows[state.selection].pane_id) != nullptr},
        {u"commandLoaded"_s, state.selection < rows.size() && (rows[state.selection].command_complete || (selected_detail && state.command_phase == application::history::HistoryPhase::ready))},
        {u"canOlder"_s, browser.canPage(application::history::HistoryPage::older)},
        {u"hasMore"_s, state.has_more},
        {u"matchFuzzy"_s, browser.match() == HistoryMatch::fuzzy},
        {u"canNewer"_s, browser.canPage(application::history::HistoryPage::newer)},
        {u"offset"_s, static_cast<qulonglong>(state.page_offset)},
        {u"selection"_s, static_cast<int>(state.selection)},
        {u"count"_s, static_cast<int>(browser.rows().size())},
        {u"canSubmit"_s, browser.canSubmit()},
        {u"commandPhase"_s, phaseName(selected_detail ? state.command_phase : application::history::HistoryPhase::idle)},
        {u"enterRuns"_s, session.configuration.history.enter_runs},
        {u"inspecting"_s, state.inspecting},
        {u"outputPhase"_s, phaseName(state.output_phase)},
        {u"outputTruncated"_s, state.output_truncated},
        {u"deleting"_s, browser.deleting()},
        {u"error"_s, toQString(browser.error())},
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

    for (const auto& fact : details.lines()) {
      facts.append(QVariantMap{
          {u"label"_s, toQString(fact.label)},
          {u"text"_s, toQString(fact.text)},
          {u"color"_s, QString::fromLatin1(palette_names[static_cast<std::size_t>(fact.color)])},
          {u"mono"_s, fact.mono},
      });
    }

    return {
        {u"identity"_s, QString::number(entry.id)},
        {u"facts"_s, facts},
        {u"heading"_s, toQString(application::history::HistoryInspectionFacts::outputHeading(state.output_phase, state.output_truncated, browser.output().size()).view())},
    };
  }

  void HistoryController::search(const QString& query) {
    const auto measured = Utf16Prefix::fit(QStringView{query}, application::history::HistorySearch::maximum_query_bytes, utf16Encoding());

    query_ = query.first(static_cast<qsizetype>(measured.units));
    if (!query_.isValidUtf16()) {
      query_ = QString::fromUtf8(query_.toUtf8());
    }

    // Typing again takes back an Enter that waited for the search.
    pending_submit_.reset();
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

    // A row still running is read again, which brings its duration and end; the others only need
    // their ages told anew.
    const auto& rows = application::history::view(store_.session()).rows();
    const bool running = std::ranges::any_of(rows, [](const auto& row) {
      return row.status == HistoryStatus::running;
    });

    if (running) {
      interact([&] {
        application::history::refresh(store_.sessionMut());
      });

      return;
    }

    buildRows();
    state_ = buildState();
    inspection_ = buildInspection();
    changed();
  }

  void HistoryController::query() {
    try {
      const auto query = query_.toUtf8();

      application::history::search(store_.sessionMut(), std::string_view{query.constData(), static_cast<std::size_t>(query.size())}, filters_);
    } catch (const std::exception& error) {
      fail(error);
    }

    synchronize();
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

      if (filters.contains(u"scope"_s)) {
        next.scope = parseScope(filters.value(u"scope"_s).toString());
      }

      if (filters.contains(u"author"_s)) {
        next.author = parseAuthor(filters.value(u"author"_s).toString());
      }

      auto query = query_;

      if (filters.contains(u"failedOnly"_s)) {
        next.failed_only = filters.value(u"failedOnly"_s).toBool();
        // The chip turns off what a leading ! turned on too: the ! leaves the search.
        if (!next.failed_only) {
          query = withoutFailedMark(query);
        }
      }

      filters_ = next;
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

    if (!isOpen() || (busy() && action != Action::inspect)) {
      return;
    }

    interact([&] {
      auto& session = store_.sessionMut();

      if (action == Action::older || action == Action::newer) {
        application::history::page(session, action == Action::older ? application::history::HistoryPage::older : application::history::HistoryPage::newer);
      } else if (action == Action::inspect) {
        application::history::inspect(session, !application::history::view(session).state().inspecting);
      } else {
        const auto browser = application::history::view(session);
        const auto& rows = browser.rows();
        const auto identity = entry_id.isEmpty() && !rows.empty() ? rows[browser.state().selection].id : entry_id.toULongLong();

        if (action == Action::copy) {
          application::history::copy(session, identity);
          QGuiApplication::clipboard()->setText(toQString(session.clipboard()));
        } else if (action == Action::erase) {
          application::history::remove(session, identity);
        } else if (action == Action::visit) {
          application::history::visit(session, identity);
          closeRequested();
        }
      }
    });
  }

  void HistoryController::submit(std::uint64_t entry_id, bool alternate) {
    if (!isOpen()) {
      return;
    }

    interact([&] {
      if (busy()) {
        throw EncodingError{"History search is still loading"};
      }

      application::history::paste(store_.sessionMut(), entry_id, alternate);
      submitted();
      closeRequested();
    });
  }

  void HistoryController::use(int row, bool alternate) {
    if (!isOpen()) {
      return;
    }

    // The rows shown are of an older query: the search runs now, and its first row once it
    // arrives, as fzf runs its best match.
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

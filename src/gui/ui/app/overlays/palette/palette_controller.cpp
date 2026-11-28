module telar.gui.ui.app.overlays.palette;

import std;
import telar.gui.qt;
import telar.gui.ui.design.controls;
import telar.gui.ui.kit.models;
import telar.gui.ui.kit.text;
import telar.gui.foundation.forms;
import telar.gui.application;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.wire.vocabulary;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  namespace {

    std::string_view paletteBytes(const QByteArray& text) {
      return {text.constData(), static_cast<std::size_t>(text.size())};
    }

    QString navigationKey(const NavigationTarget& target) {
      if (const auto* workspace = std::get_if<WorkspaceLocation>(&target)) {
        return u"context:"_s + QString::number(workspace->id);
      }

      if (const auto* tab = std::get_if<TabLocation>(&target)) {
        return u"tab:"_s + QString::number(static_cast<int>(tab->workspace.kind)) + QLatin1Char(':') + QString::number(tab->workspace.id) + QLatin1Char(':') + QString::number(tab->tab_id);
      }

      const auto agent = std::get<AgentNavigationTarget>(target);

      return u"agent:"_s + QString::number(agent.pane_id) + QLatin1Char(':') + QString::number(agent.pane_generation);
    }

    QString groupName(application::palette::PaletteRowKind kind) {
      switch (kind) {
      case application::palette::PaletteRowKind::context:
        return u"Contexts"_s;
      case application::palette::PaletteRowKind::tab:
        return u"Tabs"_s;
      case application::palette::PaletteRowKind::agent:
        return u"Agents"_s;
      case application::palette::PaletteRowKind::action:
        return u"Actions"_s;
      case application::palette::PaletteRowKind::machine:
        return u"Machines"_s;
      case application::palette::PaletteRowKind::pick:
      case application::palette::PaletteRowKind::suggestion:
        return {};
      }

      // A kind outside the enum names no group.
      return {};
    }

    // The selected row's kind, which picks the shortcuts the footer shows.
    QString kindName(application::palette::PaletteRowKind kind) {
      switch (kind) {
      case application::palette::PaletteRowKind::action:
        return u"action"_s;
      case application::palette::PaletteRowKind::machine:
        return u"machine"_s;
      case application::palette::PaletteRowKind::suggestion:
        return u"suggestion"_s;
      case application::palette::PaletteRowKind::context:
      case application::palette::PaletteRowKind::tab:
      case application::palette::PaletteRowKind::agent:
      case application::palette::PaletteRowKind::pick:
        return u"navigation"_s;
      }

      // A kind outside the enum shows the navigation shortcuts.
      return u"navigation"_s;
    }

    application::palette::PaletteRowKind kindOf(const PaletteTarget& target) noexcept {
      using Kind = application::palette::PaletteRowKind;

      if (const auto* navigation = std::get_if<NavigationTarget>(&target)) {
        if (std::holds_alternative<WorkspaceLocation>(*navigation)) {
          return Kind::context;
        }

        return std::holds_alternative<TabLocation>(*navigation) ? Kind::tab : Kind::agent;
      }

      if (std::holds_alternative<PaletteAction>(target)) {
        return Kind::action;
      }

      return std::holds_alternative<PaletteAsk>(target) ? Kind::suggestion : Kind::machine;
    }

    template <typename Matches>
    void add(Matches& matches, PaletteTarget target, std::string_view label, std::string_view query) {
      if (const auto score = application::palette::PaletteScore::of(label, query)) {
        matches.addScored(std::move(target), *score);
      }
    }

    QVariantMap navigationRecord(const NavigationTarget& target, const application::palette::NavigationLabel& label, application::palette::PaletteRowKind kind) {
      const auto text = label.view();
      const auto split = std::min(text.find(application::palette::NavigationLabel::detail_separator), text.size());
      auto primary = text.substr(0, split);
      auto secondary = text.substr(split);

      secondary.remove_prefix(std::min(secondary.find_first_not_of(' '), secondary.size()));
      if (kind == application::palette::PaletteRowKind::tab && primary.starts_with(application::palette::NavigationLabel::tab_prefix)) {
        primary.remove_prefix(application::palette::NavigationLabel::tab_prefix.size());
      }

      QString glyph = u""_s;

      if (kind == application::palette::PaletteRowKind::context) {
        glyph = u""_s;
      } else if (kind == application::palette::PaletteRowKind::tab) {
        glyph = u""_s;
      }

      return {
          {u"key"_s, navigationKey(target)},
          {u"kind"_s, static_cast<int>(kind)},
          {u"icon"_s, glyph},
          {u"primary"_s, toQString(primary)},
          {u"secondary"_s, toQString(secondary)},
          {u"hint"_s, QString{}},
          {u"detailBelow"_s, false},
          {u"shortcut"_s, false},
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
    changed();
  }

  void PaletteController::setCommands(QVariantList commands) {
    commands_ = std::move(commands);
  }

  void PaletteController::open(application::palette::PaletteMode mode) {
    parent_.reset();
    editor_restore_ = {};
    if (mode == application::palette::PaletteMode::suggest) {
      application::palette::suggest(store_.sessionMut());
    }

    query_ = mode == application::palette::PaletteMode::all ? QString{} : QString{QChar{static_cast<char>(mode)}};
    selection_ = 0;
    ++revision_;
    static_cast<void>(updateResults());
    changed();
  }

  void PaletteController::forget() noexcept {
    parent_.reset();
    editor_restore_ = {};
  }

  void PaletteController::publish() {
    changed();
  }

  void PaletteController::reportQueryLimit(qulonglong requested_bytes) {
    if (!isOpen() || requested_bytes <= application::palette::PaletteQuery::maximum_bytes) {
      return;
    }

    application::notifications::reportLimit(store_.sessionMut(), {.name = "prompt.field_bytes", .noun = "bytes", .value = application::palette::PaletteQuery::maximum_bytes, .requested = requested_bytes, .route = {}});
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
      application::palette::discard(store_.sessionMut());
    }

    static_cast<void>(updateResults());
    changed();

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
      changed();
    }
  }

  void PaletteController::synchronize() {
    if (isOpen() && updateResults()) {
      changed();
    }
  }

  void PaletteController::refreshMachines() {
    const auto current = mode();
    if (current == application::palette::PaletteMode::machines || current == application::palette::PaletteMode::all) {
      synchronize();
    }
  }

  void PaletteController::collectNavigation(Matches& matches, std::string_view query) const {
    const auto& session = store_.session();

    for (const auto& workspace : session.workspaces()) {
      application::palette::NavigationLabel label;

      label.append(workspace.name);
      label.appendDetail(workspace.branch);
      add(matches, NavigationTarget{workspace.location}, label.view(), query);
    }

    ds::Array<const Tab<Memory>*, GuiSession::maximum_workspace_tabs> tabs{};
    std::size_t count = 0;
    const auto* active = session.activeTab();

    for (const auto& tab : session.tabs) {
      if (active != nullptr && sameWorkspace(tab->location.workspace, active->location.workspace) && count < tabs.size()) {
        tabs.atMut(count++) = &tab.get();
      }
    }

    const auto ordered = tabs.viewMut().first(count);

    std::ranges::sort(ordered, {}, &Tab<Memory>::position);
    for (const auto* tab : ordered) {
      application::palette::NavigationLabel label;

      label.append(application::palette::NavigationLabel::tab_prefix);
      label.append(tab->label.empty() ? application::tabApplicationName(*tab, session.findPane(tab->focused_pane)) : std::string_view{tab->label});
      add(matches, NavigationTarget{tab->location}, label.view(), query);
    }

    for (const auto& agent : session.agents()) {
      application::palette::NavigationLabel label;

      label.append(agent.provider_name);
      label.appendDetail(agent.title);
      label.appendDetail(agent.workspace_label);
      add(matches, NavigationTarget{AgentNavigationTarget{.pane_id = agent.pane_id, .pane_generation = agent.pane_generation}}, label.view(), query);
    }
  }

  void PaletteController::collectActions(Matches& matches, std::string_view query) const {
    for (const auto& entry : commands_) {
      const auto command = entry.toMap();
      const auto label = command.value(u"label"_s).toString().toUtf8();
      auto score = application::palette::PaletteScore::of(paletteBytes(label), query);
      if (!score) {
        continue;
      }

      // A short query is a guess: an action that closes something waits below every other match.
      if (command.value(u"destructive"_s).toBool() && query.size() < destructive_query_bytes) {
        score = std::max<std::uint32_t>(2, *score / 2);
      }

      matches.addScored(PaletteAction{.value = command.value(u"action"_s).toInt()}, *score);
    }
  }

  void PaletteController::collectMachines(Matches& matches, std::string_view query) const {
    const auto machines = application::machines::MachinePicker::collect(store_.machines(), query, application::palette::PaletteScore::of);

    for (const auto& match : machines.rows()) {
      matches.addScored(application::machines::MachinePickerTarget{.machine = match.target}, match.score);
    }
  }

  bool PaletteController::updateResults() {
    const auto text = query_.toUtf8();
    const auto query = application::palette::PaletteQuery::parse(paletteBytes(text));
    if (query.mode == application::palette::PaletteMode::machines) {
      return updateMachineResults(query.text);
    }

    // An empty query lists what to navigate to; typing searches every kind.
    const auto all = query.mode == application::palette::PaletteMode::all;
    const auto searching = all && !query.text.empty();
    Matches matches;

    if (all || query.mode == application::palette::PaletteMode::navigate) {
      collectNavigation(matches, query.text);
    }

    if (searching) {
      collectMachines(matches, query.text);
    }

    if (searching || query.mode == application::palette::PaletteMode::actions) {
      collectActions(matches, query.text);
    }

    // Real matches score at least 2, so the suggestion row always comes last.
    if (searching) {
      matches.addScored(PaletteAsk{}, 1);
    }

    // Rows stay grouped by kind; the groups follow the rank of their best row.
    const auto ranked = matches.rows();
    constexpr std::size_t kind_count = static_cast<std::size_t>(application::palette::PaletteRowKind::suggestion) + 1;
    ds::Array<application::palette::PaletteRowKind, kind_count> order{};
    std::size_t groups = 0;

    for (const auto& match : ranked) {
      const auto kind = kindOf(match.target);
      const auto seen = std::span{order}.first(groups);
      if (std::ranges::find(seen, kind) == seen.end()) {
        order.atMut(groups++) = kind;
      }
    }

    QVariantList rows;
    std::size_t count = 0;

    rows.reserve(static_cast<qsizetype>(ranked.size()));
    for (const auto kind : std::span{order}.first(groups)) {
      for (const auto& match : ranked) {
        if (kindOf(match.target) == kind) {
          rows.append(record(match.target, query.text));
          targets_.atMut(count) = match.target;
          kinds_.atMut(count++) = kind;
        }
      }
    }

    if (rows == rows_) {
      return false;
    }

    rows_ = std::move(rows);
    selection_ = rows_.empty() ? 0 : std::min(selection_, static_cast<std::size_t>(rows_.size() - 1));
    ++revision_;
    ++rebuilds_;

    return true;
  }

  bool PaletteController::updateMachineResults(std::string_view query) {
    const auto matches = application::machines::MachinePicker::collect(store_.machines(), query);
    QVariantList rows;

    rows.reserve(static_cast<qsizetype>(matches.rows().size()) + 1);
    for (const auto& match : matches.rows()) {
      rows.append(machineRecord({.machine = match.target}));
    }

    rows.append(machineRecord({.machine = ds::none}));
    if (rows == rows_) {
      return false;
    }

    for (std::size_t index = 0; index < matches.rows().size(); ++index) {
      targets_.atMut(index) = application::machines::MachinePickerTarget{.machine = matches.rows()[index].target};
      kinds_.atMut(index) = application::palette::PaletteRowKind::machine;
    }

    const auto last = matches.rows().size();

    targets_.atMut(last) = application::machines::MachinePickerTarget{.machine = ds::none};
    kinds_.atMut(last) = application::palette::PaletteRowKind::machine;
    rows_ = std::move(rows);
    selection_ = std::min(selection_, static_cast<std::size_t>(rows_.size() - 1));
    ++revision_;
    ++rebuilds_;

    return true;
  }

  QVariantMap PaletteController::record(const PaletteTarget& target, std::string_view query) const {
    if (std::holds_alternative<PaletteAsk>(target)) {
      return {
          {u"key"_s, u"suggest:query"_s},
          {u"kind"_s, static_cast<int>(application::palette::PaletteRowKind::suggestion)},
          {u"icon"_s, u"\uf0eb"_s},
          {u"primary"_s, u"Suggest a command for \u201c"_s + toQString(query) + u"\u201d"_s},
          {u"secondary"_s, QString{}},
          {u"hint"_s, QString{}},
          {u"shortcut"_s, false},
          {u"detailBelow"_s, false},
      };
    }

    if (const auto* machine = std::get_if<application::machines::MachinePickerTarget>(&target)) {
      return machineRecord(*machine);
    }

    if (const auto* action = std::get_if<PaletteAction>(&target)) {
      for (const auto& entry : commands_) {
        const auto command = entry.toMap();
        if (command.value(u"action"_s).toInt() == action->value) {
          return {
              {u"key"_s, u"action:"_s + QString::number(action->value)},
              {u"kind"_s, static_cast<int>(application::palette::PaletteRowKind::action)},
              {u"icon"_s, u""_s},
              {u"primary"_s, command.value(u"label"_s)},
              {u"secondary"_s, QString{}},
              {u"hint"_s, command.value(u"shortcut"_s)},
              {u"shortcut"_s, true},
              {u"detailBelow"_s, false},
              {u"destructive"_s, command.value(u"destructive"_s)},
          };
        }
      }

      return {};
    }

    const auto& session = store_.session();
    const auto& navigation = std::get<NavigationTarget>(target);
    application::palette::NavigationLabel label;

    if (const auto* workspace = std::get_if<WorkspaceLocation>(&navigation)) {
      const auto* const found = std::ranges::find_if(session.workspaces(), [&](const auto& row) {
        return sameWorkspace(row.location, *workspace);
      });
      if (found != session.workspaces().end()) {
        label.append(found->name);
        label.appendDetail(found->branch);
      }

      return navigationRecord(navigation, label, application::palette::PaletteRowKind::context);
    }

    if (const auto* tab = std::get_if<TabLocation>(&navigation)) {
      const auto* const found = std::ranges::find_if(session.tabs, [&](const auto& row) {
        return sameTab(row->location, *tab);
      });
      if (found != session.tabs.end()) {
        label.append(application::palette::NavigationLabel::tab_prefix);
        label.append((*found)->label.empty() ? application::tabApplicationName(*(*found), session.findPane((*found)->focused_pane)) : std::string_view{(*found)->label});
      }

      return navigationRecord(navigation, label, application::palette::PaletteRowKind::tab);
    }

    const auto identity = std::get<AgentNavigationTarget>(navigation);
    const auto* const found = std::ranges::find_if(session.agents(), [&](const auto& row) {
      return row.pane_id == identity.pane_id && row.pane_generation == identity.pane_generation;
    });
    if (found == session.agents().end()) {
      return {};
    }

    label.append(found->provider_name);
    auto result = navigationRecord(navigation, label, application::palette::PaletteRowKind::agent);
    constexpr std::string_view separator = " · ";
    const auto detail_size = found->provider_name.size() + separator.size() + found->workspace_label.size();
    if (detail_size <= application::palette::NavigationLabel::capacity) {
      label.append(separator);
      label.append(found->workspace_label);
    }

    result.insert(u"primary"_s, toQString(found->title.empty() ? std::string_view{found->provider_name} : std::string_view{found->title}));
    result.insert(u"secondary"_s, toQString(label.view()));
    result.insert(u"hint"_s, QString{});
    result.insert(u"detailBelow"_s, true);

    return result;
  }

  QVariantMap PaletteController::machineRecord(application::machines::MachinePickerTarget target) const {
    QVariantMap result{
        {u"kind"_s, static_cast<int>(application::palette::PaletteRowKind::machine)},
        {u"detailBelow"_s, false},
        {u"shortcut"_s, false},
    };

    if (!target.machine) {
      result.insert(u"key"_s, u"machine:add"_s);
      result.insert(u"icon"_s, u"+"_s);
      result.insert(u"primary"_s, u"Add machine…"_s);
      result.insert(u"secondary"_s, u"a label and its pairing address"_s);
      result.insert(u"hint"_s, QString{});

      return result;
    }

    const auto token = *target.machine;
    const auto& row = store_.machines().row(token.slot);
    QString state;

    if (!row.enabled) {
      state = u"disabled · enter enables"_s;
    } else if (token.slot == store_.machines().active()) {
      state = u"shown"_s;
    } else {
      switch (row.phase) {
      case application::machines::MachinePhase::connected:
        state = row.cpu_percent ? QString::number(*row.cpu_percent) + u"% cpu"_s : u"connected"_s;
        break;
      case application::machines::MachinePhase::connecting:
        state = u"connecting"_s;
        break;
      case application::machines::MachinePhase::lost:
        state = u"unreachable · enter retries"_s;
        break;
      case application::machines::MachinePhase::failed:
        state = row.needs_setup ? u"no telar for this build · enter sets it up"_s : u"failed · enter retries"_s;
        break;
      case application::machines::MachinePhase::stopped:
        state = u"disabled"_s;
        break;
      }
    }

    result.insert(u"key"_s, u"machine:"_s + QString::number(token.slot) + QLatin1Char(':') + QString::number(token.generation));
    result.insert(u"icon"_s, row.attention ? u"●"_s : u"○"_s);
    result.insert(u"primary"_s, toQString(row.label.view()));
    result.insert(u"secondary"_s, row.destination.view().empty() ? u"this machine"_s : toQString(row.destination.view()));
    result.insert(u"hint"_s, state);

    return result;
  }

  QVariantMap PaletteController::state() const {
    const auto text = query_.toUtf8();
    const auto query = application::palette::PaletteQuery::parse(paletteBytes(text));
    const auto selected = static_cast<qsizetype>(selection_);

    return {
        {u"mode"_s, static_cast<int>(query.mode)},
        {u"editorText"_s, query_},
        {u"query"_s, toQString(query.text)},
        {u"selection"_s, selected},
        {u"selectedKey"_s, selected < rows_.size() ? rows_[selected].toMap().value(u"key"_s) : QVariant{}},
        {u"selectedKind"_s, selected < rows_.size() ? kindName(kinds_[selection_]) : QString{}},
        {u"revision"_s, QString::number(revision_)},
        {u"count"_s, rows_.size()},
        {u"maximumQueryBytes"_s, static_cast<qulonglong>(application::palette::PaletteQuery::maximum_bytes)},
        {u"editorRestoreRevision"_s, editor_restore_.revision == 0 ? QString{} : QString::number(editor_restore_.revision)},
        {u"editorAnchor"_s, editor_restore_.anchor},
        {u"editorCursor"_s, editor_restore_.cursor},
    };
  }

  QVariantMap PaletteController::geometry() const {
    const auto density = display_.density;
    const Rect viewport{.width = static_cast<float>(display_.viewport.width), .height = static_cast<float>(display_.viewport.height)};
    const auto text = query_.toUtf8();
    const auto query = application::palette::PaletteQuery::parse(paletteBytes(text));
    const auto geometry = application::palette::PaletteGeometry::measure(viewport, display_.chrome, {.pick_rows = ds::none, .suggest = query.mode == application::palette::PaletteMode::suggest});
    const auto local = [&](Rect area) {
      area.x -= geometry.bounds.x;
      area.y -= geometry.bounds.y;

      return toQRectF(area, density);
    };

    const auto kinds = std::span{kinds_}.first(static_cast<std::size_t>(rows_.size()));
    const auto visible = application::palette::PaletteRowWindow::measure(kinds, selection_, geometry, display_.chrome, true);
    QVariantList rows;

    rows.reserve(static_cast<qsizetype>(visible.count));
    for (std::size_t index = 0; index < visible.count; ++index) {
      const auto& placement = visible.rows[index];
      auto record = rows_[static_cast<qsizetype>(placement.index)].toMap();

      record.insert(u"bounds"_s, local(placement.bounds));
      record.insert(u"groupBounds"_s, local(placement.group));
      record.insert(u"groupLabel"_s, groupName(kinds[placement.index]));
      record.insert(u"selected"_s, placement.index == selection_);
      rows.append(QVariant{std::in_place_type<QVariantMap>, std::move(record)});
    }

    return {
        {u"bounds"_s, toQRectF(geometry.bounds, density)},
        {u"heading"_s, local(geometry.heading)},
        {u"search"_s, local(geometry.search)},
        {u"results"_s, local(geometry.results)},
        {u"footer"_s, local(geometry.footer)},
        {u"rows"_s, rows},
    };
  }

  ds::Option<PaletteController::Choice> PaletteController::chosen(const QVariantMap& choice) const {
    const auto key = choice.value(u"key"_s).toString();
    const auto revision = choice.value(u"revision"_s).toString();
    if (!isOpen() || revision != QString::number(revision_)) {
      return ds::none;
    }

    const auto found = std::ranges::find_if(rows_, [&](const auto& entry) {
      return entry.toMap().value(u"key"_s).toString() == key;
    });
    if (found == rows_.end()) {
      return ds::none;
    }

    const auto index = static_cast<std::size_t>(found - rows_.begin());

    return Choice{.target = targets_[index], .index = index};
  }

  ds::Option<application::machines::MachinePickerTarget> PaletteController::chosenMachine(const QVariantMap& choice) const {
    if (!isOpen() || choice.value(u"revision"_s).toString() != QString::number(revision_)) {
      return ds::none;
    }

    const auto key = choice.value(u"key"_s).toString();

    for (qsizetype index = 0; index < rows_.size(); ++index) {
      if (rows_[index].toMap().value(u"key"_s).toString() == key) {
        if (const auto* target = std::get_if<application::machines::MachinePickerTarget>(&targets_[static_cast<std::size_t>(index)])) {
          return *target;
        }
      }
    }

    return ds::none;
  }

  PaletteController::Parent PaletteController::parentFor(const QVariantMap& choice, std::size_t index) const {
    const auto cursor = choice.value(u"cursor"_s, query_.size()).toInt();
    const auto anchor = choice.value(u"anchor"_s, cursor).toInt();

    return {.query = query_, .selection = index, .editor = {.anchor = std::clamp(anchor, 0, static_cast<int>(query_.size())), .cursor = std::clamp(cursor, 0, static_cast<int>(query_.size()))}};
  }

  void PaletteController::adoptParent(Parent parent) {
    parent_ = std::move(parent);
    changed();
  }

  bool PaletteController::restoreParent() {
    if (!isOpen() || !parent_) {
      return false;
    }

    auto parent = std::move(parent_.getMut());

    open(application::palette::PaletteMode::actions);
    query_ = std::move(parent.query);
    selection_ = parent.selection;
    static_cast<void>(updateResults());
    editor_restore_ = parent.editor;
    editor_restore_.revision = ++revision_;
    changed();
    showRequested();

    return true;
  }

  void PaletteController::activate(const QVariantMap& choice) {
    const auto found = chosen(choice);
    if (!found) {
      return;
    }

    const auto& target = found->target;
    if (std::holds_alternative<PaletteAsk>(target)) {
      interact([&] {
        auto parent = parentFor(choice, found->index);
        const auto encoded = query_.toUtf8();
        const auto task = toQString(application::palette::PaletteQuery::parse(paletteBytes(encoded)).text);

        open(application::palette::PaletteMode::suggest);
        query_.append(task);
        static_cast<void>(updateResults());
        showRequested();
        adoptParent(std::move(parent));
      });

      return;
    }

    if (const auto* machine = std::get_if<application::machines::MachinePickerTarget>(&target)) {
      machineRequested(*machine, choice.value(u"alternate"_s, false).toBool());

      return;
    }

    if (const auto* navigation = std::get_if<NavigationTarget>(&target)) {
      interact([&] {
        if (navigate(*navigation)) {
          closeRequested();
        }
      });

      return;
    }

    const auto action = std::get<PaletteAction>(target);
    if (action.value != suggestion_.value) {
      actionRequested(action);

      return;
    }

    interact([&] {
      auto parent = parentFor(choice, found->index);

      open(application::palette::PaletteMode::suggest);
      showRequested();
      adoptParent(std::move(parent));
    });
  }

  bool PaletteController::navigate(const NavigationTarget& target) {
    auto& session = store_.sessionMut();

    if (const auto* workspace = std::get_if<WorkspaceLocation>(&target)) {
      const auto* const found = std::ranges::find_if(session.workspaces(), [&](const auto& row) {
        return sameWorkspace(row.location, *workspace);
      });
      if (found == session.workspaces().end()) {
        return false;
      }

      application::workbench::selectWorkspace(session, *workspace);

      return true;
    }

    if (const auto* tab = std::get_if<TabLocation>(&target)) {
      const auto* const found = std::ranges::find_if(session.tabs, [&](const auto& row) {
        return sameTab(row->location, *tab);
      });
      if (found == session.tabs.end()) {
        return false;
      }

      application::workbench::selectTab(session, *tab);

      return true;
    }

    const auto agent = std::get<AgentNavigationTarget>(target);

    return application::activity::chooseAgent(session, agent.pane_id, agent.pane_generation);
  }

  void PaletteController::submitSuggestion(const QString& revision) {
    const auto encoded = query_.toUtf8();
    const auto query = application::palette::PaletteQuery::parse(paletteBytes(encoded));
    if (!isOpen() || query.mode != application::palette::PaletteMode::suggest || revision != suggestionRevision()) {
      return;
    }

    interact([&] {
      if (application::palette::submit(store_.sessionMut(), query.text)) {
        closeRequested();
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
        {u"heading"_s, toQString(application::palette::SuggestionLabels::heading(phase))},
        {u"message"_s, toQString(application::palette::SuggestionLabels::message(phase, suggestion.status))},
        {u"button"_s, toQString(application::palette::SuggestionLabels::button(phase))},
        {u"footer"_s, toQString(application::palette::SuggestionLabels::footer(phase))},
        {u"text"_s, toQString(suggestion.text)},
        {u"phase"_s, static_cast<int>(phase)},
        {u"ready"_s, phase == application::palette::SuggestionPhase::ready},
        {u"failed"_s, phase == application::palette::SuggestionPhase::failed},
        {u"canSubmit"_s, application::palette::SuggestionLabels::canSubmit(phase, query.text)},
        {u"revision"_s, suggestionRevision()},
        {u"hasParent"_s, parent_.hasValue()},
    };
  }

  QVariantMap PaletteController::suggestionGeometry() const {
    const auto density = display_.density;
    const Rect viewport{.width = static_cast<float>(display_.viewport.width), .height = static_cast<float>(display_.viewport.height)};
    const auto palette = application::palette::PaletteGeometry::measure(viewport, display_.chrome, {.pick_rows = ds::none, .suggest = true});
    const auto geometry = application::palette::SuggestionGeometry::measure(palette, display_.chrome, parent_.hasValue());
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
      const auto& font = session.configuration.font;
      const auto resolved = FormTextGrid::resolve(toQString(font.family.view()), toQString(font.style.view()), display_.chrome.body);

      grid = resolved.record(density);
      SuggestionPreview preview{suggestion.text, geometry.preview, resolved.metrics};

      while (const auto line = preview.next()) {
        lines.append(QVariantMap{{u"text"_s, toQString(line->text)}, {u"bounds"_s, local(line->bounds)}, {u"shortened"_s, line->shortened}});
      }
    }

    return {
        {u"title"_s, local(geometry.title)},
        {u"back"_s, local(geometry.back)},
        {u"heading"_s, local(geometry.heading)},
        {u"body"_s, local(geometry.body)},
        {u"message"_s, local(geometry.message)},
        {u"preview"_s, local(geometry.preview)},
        {u"footer"_s, local(geometry.footer_caption)},
        {u"button"_s, local(geometry.button)},
        {u"separator"_s, local(geometry.separator)},
        {u"previewRadius"_s, static_cast<double>(display_.chrome.textPx(application::palette::SuggestionGeometry::preview_radius)) / density},
        {u"messageAlpha"_s, application::palette::SuggestionGeometry::message_alpha},
        {u"titleAlpha"_s, application::palette::SuggestionGeometry::title_alpha},
        {u"grid"_s, std::move(grid)},
        {u"lines"_s, std::move(lines)},
    };
  }

}

#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "monitor_controller.hpp"
#include "ui/kit/models/projection.hpp"
#include <QClipboard>
#include <QGuiApplication>
#include <QStringList>
#include <QVariantList>

import telar.gui.application;

namespace telar::gui::qt {
  namespace {

    using application::monitor::MonitorLimits;
    using application::monitor::MonitorScope;
    using application::monitor::MonitorSort;
    using application::monitor::ProcessInstance;
    using application::monitor::ProcessSignal;

    constexpr ds::Array<const char*, 5> sort_names{"cpu", "memory", "threads", "pid", "name"};
    constexpr ds::Array<const char*, 3> scope_names{"all", "telar", "agents"};
    constexpr ds::Array<const char*, 6> state_names{"unknown", "running", "sleeping", "idle", "stopped", "zombie"};
    constexpr std::size_t microsecond_digits = 6;
    constexpr int decimal = 10;
    // The runtime counts shares in permille; QML shows percents.
    constexpr double permille_per_percent = 10.0;
    constexpr int least_nice = -20;
    constexpr int most_nice = 20;

    QString started(const ProcessInstance& instance) {
      return QStringLiteral("%1.%2").arg(instance.started_seconds).arg(instance.started_microseconds, static_cast<int>(microsecond_digits), decimal, QLatin1Char('0'));
    }

    ProcessInstance instance(int pid, const QString& text) {
      const auto parts = text.split(QLatin1Char('.'));
      ProcessInstance result{.pid = pid};

      if (parts.size() == 2) {
        result.started_seconds = parts[0].toULongLong();
        result.started_microseconds = parts[1].toULongLong();
      }

      return result;
    }

    // The agent telar recognizes in the process, else its own name.
    QString program(const application::monitor::ProcessRow& row) {
      if (row.agent != AgentProvider::unknown) {
        const auto name = runtime::describeProvider(row.agent).name;
        if (!name.empty()) {
          return toQString(name);
        }
      }

      return toQString(row.name.view());
    }

    QVariantMap record(const application::monitor::ProcessRow& row) {
      return {
          {QStringLiteral("key"), QStringLiteral("%1:%2").arg(row.instance.pid).arg(started(row.instance))},
          {QStringLiteral("pid"), row.instance.pid},
          {QStringLiteral("started"), started(row.instance)},
          {QStringLiteral("parent"), row.parent},
          {QStringLiteral("user"), toQString(row.user.view())},
          {QStringLiteral("name"), toQString(row.name.view())},
          {QStringLiteral("program"), program(row)},
          {QStringLiteral("command"), toQString(row.command.view())},
          {QStringLiteral("state"), QString::fromLatin1(state_names[static_cast<std::size_t>(row.state)])},
          {QStringLiteral("measured"), row.measured},
          {QStringLiteral("cpu"), static_cast<double>(row.cpu_permille) / permille_per_percent},
          {QStringLiteral("memory"), static_cast<double>(row.resident_bytes)},
          {QStringLiteral("threads"), row.threads},
          {QStringLiteral("nice"), row.nice},
          {QStringLiteral("pane"), static_cast<double>(row.pane_id)},
          {QStringLiteral("agent"), row.agent != AgentProvider::unknown},
          {QStringLiteral("depth"), row.depth},
      };
    }

    template <std::size_t Size>
    ds::Option<std::size_t> indexOf(const ds::Array<const char*, Size>& names, const QString& name) {
      for (std::size_t index = 0; index < Size; ++index) {
        if (name == QLatin1StringView{names[index]}) {
          return index;
        }
      }

      return ds::none;
    }

  }

  MonitorController::MonitorController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store),
        rows_(this) {
    timer_.setInterval(refresh_milliseconds);
    connect(&timer_, &QTimer::timeout, this, &MonitorController::refresh);
  }

  bool MonitorController::showing() const {
    return store_.dialog().kind == Store::Dialog::monitor;
  }

  bool MonitorController::available() const {
    return application::monitor::available(store_.session());
  }

  QAbstractItemModel* MonitorController::rows() noexcept {
    return &rows_;
  }

  void MonitorController::opened() {
    revision_ = 0;
    refresh();
    timer_.start();
    emit changed();
  }

  void MonitorController::refresh() {
    if (!showing()) {
      timer_.stop();
      return;
    }

    application::monitor::refresh(store_.sessionMut());
  }

  // A change of the view asks again at once rather than at the next tick.
  void MonitorController::restart() {
    refresh();
    timer_.start();
    emit changed();
  }

  void MonitorController::synchronize() {
    const auto& state = application::monitor::state(store_.session());
    if (state.revision == revision_) {
      return;
    }

    revision_ = state.revision;
    QList<QVariantMap> records;

    records.reserve(static_cast<qsizetype>(state.processes.size()));
    for (const auto& row : state.processes) {
      records.push_back(record(row));
    }

    rows_.replaceRows(std::move(records));
    emit changed();
  }

  QVariantMap MonitorController::host() const {
    const auto& state = application::monitor::state(store_.session());
    QVariantList cores;
    QVariantList disks;
    QVariantList interfaces;

    for (const auto core : state.cores) {
      cores.push_back(static_cast<double>(core) / permille_per_percent);
    }

    for (const auto& disk : state.disks) {
      disks.push_back(QVariantMap{
          {QStringLiteral("path"), toQString(disk.path.view())},
          {QStringLiteral("type"), toQString(disk.type.view())},
          {QStringLiteral("total"), static_cast<double>(disk.total_bytes)},
          {QStringLiteral("used"), static_cast<double>(disk.used_bytes)},
          {QStringLiteral("available"), static_cast<double>(disk.available_bytes)},
      });
    }

    for (const auto& interface : state.interfaces) {
      interfaces.push_back(QVariantMap{
          {QStringLiteral("name"), toQString(interface.name.view())},
          {QStringLiteral("received"), static_cast<double>(interface.received_per_second)},
          {QStringLiteral("sent"), static_cast<double>(interface.sent_per_second)},
      });
    }

    return {
        {QStringLiteral("cpu"), static_cast<double>(state.cpu_permille) / permille_per_percent},
        {QStringLiteral("cores"), cores},
        {QStringLiteral("memoryTotal"), static_cast<double>(state.memory_total_bytes)},
        {QStringLiteral("memoryUsed"), static_cast<double>(state.memory_used_bytes)},
        {QStringLiteral("memoryAvailable"), static_cast<double>(state.memory_available_bytes)},
        {QStringLiteral("memoryCached"), static_cast<double>(state.memory_cached_bytes)},
        {QStringLiteral("swapTotal"), static_cast<double>(state.swap_total_bytes)},
        {QStringLiteral("swapUsed"), static_cast<double>(state.swap_used_bytes)},
        {QStringLiteral("processes"), state.process_count},
        {QStringLiteral("threads"), state.thread_count},
        {QStringLiteral("matched"), state.matched},
        {QStringLiteral("diskRead"), static_cast<double>(state.disk_read_per_second)},
        {QStringLiteral("diskWritten"), static_cast<double>(state.disk_written_per_second)},
        {QStringLiteral("disks"), disks},
        {QStringLiteral("interfaces"), interfaces},
        {QStringLiteral("ready"), state.revision != 0},
    };
  }

  QVariantMap MonitorController::view() const {
    const auto& view = application::monitor::state(store_.session()).view;

    return {
        {QStringLiteral("sort"), QString::fromLatin1(sort_names[static_cast<std::size_t>(view.sort)])},
        {QStringLiteral("reverse"), view.reverse},
        {QStringLiteral("scope"), QString::fromLatin1(scope_names[static_cast<std::size_t>(view.scope)])},
        {QStringLiteral("tree"), view.tree},
        {QStringLiteral("filter"), toQString(view.filter.view())},
        {QStringLiteral("selected"), view.selected.pid},
    };
  }

  QVariantMap MonitorController::detail() const {
    const auto& state = application::monitor::state(store_.session());
    if (!state.detail || state.view.selected.pid == 0) {
      return {};
    }

    const auto& detail = *state.detail;
    QStringList ports;

    for (std::size_t index = 0; index < detail.port_count; ++index) {
      ports.push_back(QString::number(detail.ports[index]));
    }

    auto result = record(detail.process);

    result.insert(QStringLiteral("arguments"), toQString(detail.arguments.view()));
    result.insert(QStringLiteral("directory"), toQString(detail.directory.view()));
    result.insert(QStringLiteral("ports"), ports.join(QStringLiteral(", ")));
    result.insert(QStringLiteral("children"), detail.child_count);
    return result;
  }

  QString MonitorController::error() const {
    return toQString(application::monitor::state(store_.session()).error.view());
  }

  bool MonitorController::selected() const {
    return application::monitor::state(store_.session()).view.selected.pid != 0;
  }

  void MonitorController::setSort(const QString& sort) {
    auto& view = application::monitor::view(store_.sessionMut());

    if (const auto index = indexOf(sort_names, sort)) {
      view.sort = static_cast<MonitorSort>(*index);
      restart();
    }
  }

  void MonitorController::toggleReverse() {
    auto& view = application::monitor::view(store_.sessionMut());

    view.reverse = !view.reverse;
    restart();
  }

  void MonitorController::setScope(const QString& scope) {
    auto& view = application::monitor::view(store_.sessionMut());

    if (const auto index = indexOf(scope_names, scope)) {
      view.scope = static_cast<MonitorScope>(*index);
      restart();
    }
  }

  void MonitorController::toggleTree() {
    auto& view = application::monitor::view(store_.sessionMut());

    view.tree = !view.tree;
    restart();
  }

  void MonitorController::setFilter(const QString& filter) {
    auto& view = application::monitor::view(store_.sessionMut());
    const auto bytes = filter.toUtf8();

    view.filter.assign(runtime::utf8Prefix({bytes.constData(), static_cast<std::size_t>(bytes.size())}, MonitorLimits::filter_bytes));
    restart();
  }

  void MonitorController::select(int pid, const QString& started) {
    application::monitor::view(store_.sessionMut()).selected = instance(pid, started);
    restart();
  }

  void MonitorController::clearSelection() {
    application::monitor::view(store_.sessionMut()).selected = {};
    restart();
  }

  void MonitorController::signal(const QString& name) {
    static constexpr ds::Array<const char*, 4> names{"TERM", "KILL", "STOP", "CONT"};
    static constexpr ds::Array<ProcessSignal, 4> kinds{ProcessSignal::terminate, ProcessSignal::kill, ProcessSignal::stop, ProcessSignal::resume};
    // A copy: the call below changes the session the view lives in.
    const auto selected = application::monitor::state(store_.session()).view.selected;
    const auto index = indexOf(names, name);
    if (!index || selected.pid == 0) {
      return;
    }

    if (!application::monitor::signal(store_.sessionMut(), selected, kinds[*index])) {
      emit failed(QStringLiteral("The monitor is busy with another request; try again"));
    }
  }

  void MonitorController::renice(int nice) {
    const auto selected = application::monitor::state(store_.session()).view.selected;
    if (selected.pid == 0) {
      return;
    }

    if (!application::monitor::prioritize(store_.sessionMut(), selected, std::clamp(nice, least_nice, most_nice))) {
      emit failed(QStringLiteral("The monitor is busy with another request; try again"));
    }
  }

  void MonitorController::copyCommand() {
    const auto& state = application::monitor::state(store_.session());
    if (state.detail && state.view.selected.pid != 0) {
      QGuiApplication::clipboard()->setText(toQString(state.detail->arguments.view()));
    }
  }

  void MonitorController::focusPane() {
    const auto& state = application::monitor::state(store_.session());
    if (!state.detail || state.detail->process.pane_id == 0) {
      emit failed(QStringLiteral("This process runs in no telar pane"));
      return;
    }

    const auto pane = state.detail->process.pane_id;

    emit closeRequested();
    application::workbench::focusPane(store_.sessionMut(), pane);
  }

  void MonitorController::review(const QString& tool) {
    static constexpr ds::Array<const char*, 4> tools{"stack", "files", "logs", "debug"};
    const auto& state = application::monitor::state(store_.session());
    const auto* focused = store_.session().focusedPane();
    if (!indexOf(tools, tool) || state.view.selected.pid == 0 || focused == nullptr) {
      return;
    }

    // The new pane runs on the process's machine: its `telar` checks the instance again, runs the
    // tool, then leaves a shell.
    const auto script = QStringLiteral("\"${TELAR_BIN_PATH:-telar}\" process review %1 --started %2 --tool %3; exec \"${SHELL:-/bin/sh}\" -l").arg(state.view.selected.pid).arg(started(state.view.selected), tool).toUtf8();
    const ds::Array<std::string_view, 3> arguments{"/bin/sh", "-c", {script.constData(), static_cast<std::size_t>(script.size())}};
    const auto pane = focused->id;

    emit closeRequested();
    try {
      application::workbench::launchSplit(store_.sessionMut(), pane, arguments);
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }
  }

  bool MonitorController::perform(window_actions::Action action) {
    using window_actions::Action;

    if (!selected()) {
      return false;
    }

    switch (action) {
    case Action::process_terminate:
      signal(QStringLiteral("TERM"));
      return true;
    case Action::process_kill:
      signal(QStringLiteral("KILL"));
      return true;
    case Action::process_stop:
      signal(QStringLiteral("STOP"));
      return true;
    case Action::process_continue:
      signal(QStringLiteral("CONT"));
      return true;
    case Action::process_lower_priority: {
      constexpr int step = 5;
      const auto& state = application::monitor::state(store_.session());

      renice((state.detail ? state.detail->process.nice : 0) + step);
      return true;
    }
    case Action::process_copy_command:
      copyCommand();
      return true;
    case Action::process_focus_pane:
      focusPane();
      return true;
    case Action::process_review_stack:
      review(QStringLiteral("stack"));
      return true;
    case Action::process_review_files:
      review(QStringLiteral("files"));
      return true;
    case Action::process_review_logs:
      review(QStringLiteral("logs"));
      return true;
    case Action::none:
    case Action::new_tab:
    case Action::select_tab:
    case Action::select_tab_index:
    case Action::next_tab:
    case Action::previous_tab:
    case Action::move_tab_next:
    case Action::move_tab_previous:
    case Action::focus_left:
    case Action::focus_right:
    case Action::focus_up:
    case Action::focus_down:
    case Action::resize_left:
    case Action::resize_right:
    case Action::resize_up:
    case Action::resize_down:
    case Action::detach:
    case Action::close_tab:
    case Action::select_workspace:
    case Action::focus_pane:
    case Action::select_agent:
    case Action::split_horizontal:
    case Action::split_vertical:
    case Action::close_pane:
    case Action::fullscreen:
    case Action::toggle_sidebar:
    case Action::toggle_workspace_list:
    case Action::history:
    case Action::palette:
    case Action::goto_picker:
    case Action::leave_worktree:
    case Action::forget_gone_worktrees:
    case Action::new_workspace:
    case Action::rename_tab:
    case Action::rename_workspace:
    case Action::cancel:
    case Action::copy_mode:
    case Action::path_picker:
    case Action::suggest_command:
    case Action::machine_picker:
    case Action::next_machine:
    case Action::previous_machine:
    case Action::add_machine:
    case Action::monitor:
    case Action::process_picker:
      return false;
    }

    // An action outside the enum performs nothing.
    return false;
  }

  void MonitorController::close() {
    timer_.stop();
    emit closeRequested();
  }

}

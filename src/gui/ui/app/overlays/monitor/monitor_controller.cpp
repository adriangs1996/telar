#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "monitor_controller.hpp"
#include "ui/kit/models/projection.hpp"
#include <QClipboard>
#include <QDir>
#include <QGuiApplication>
#include <QSizeF>
#include <QStringList>
#include <QVariantList>

import telar.gui.application;

namespace telar::gui::qt {
  namespace {

    namespace monitor = application::monitor;

    using monitor::Column;
    using monitor::MonitorLayout;
    using monitor::MonitorScope;
    using monitor::MonitorSort;
    using monitor::ProcessInstance;
    using monitor::ProcessOwner;
    using monitor::ProcessSignal;
    using monitor::Tone;

    constexpr ds::Array<const char*, 5> sort_names{"cpu", "memory", "threads", "pid", "name"};
    constexpr ds::Array<const char*, 3> scope_names{"all", "telar", "agents"};
    constexpr ds::Array<const char*, 3> layout_names{"flat", "tree", "owner"};
    constexpr ds::Array<const char*, 6> state_names{"unknown", "running", "sleeping", "idle", "stopped", "zombie"};
    // The actions that ask first, in the order of MonitorController::Confirmable.
    constexpr ds::Array<const char*, 3> confirmable_names{"TERM", "KILL", "debug"};
    // The sorts `s` steps through, in the order a person meets them.
    constexpr ds::Array<MonitorSort, 5> sort_cycle{MonitorSort::cpu, MonitorSort::memory, MonitorSort::threads, MonitorSort::pid, MonitorSort::name};
    constexpr std::size_t microsecond_digits = 6;
    constexpr int decimal = 10;
    constexpr int least_nice = -20;
    constexpr int most_nice = 20;
    constexpr double whole_percent = 100;
    // The interfaces, children and ancestors a panel and a detail name before they say how many more.
    constexpr std::size_t shown_interfaces = 4;
    constexpr std::size_t shown_children = 3;
    constexpr std::size_t shown_lineage = 3;

    struct ColumnTitle {
      Column column;
      const char* title;
      // What a click on the title sorts by; none for the columns that sort nothing.
      const char* sort;
    };

    constexpr ds::Array<ColumnTitle, monitor::column_count> titles{
        ColumnTitle{.column = Column::pid, .title = "pid", .sort = "pid"},
        ColumnTitle{.column = Column::program, .title = "program", .sort = "name"},
        ColumnTitle{.column = Column::command, .title = "command", .sort = nullptr},
        ColumnTitle{.column = Column::threads, .title = "threads", .sort = "threads"},
        ColumnTitle{.column = Column::user, .title = "user", .sort = nullptr},
        ColumnTitle{.column = Column::memory, .title = "mem", .sort = "memory"},
        ColumnTitle{.column = Column::cpu, .title = "cpu%", .sort = "cpu"},
        ColumnTitle{.column = Column::owner, .title = "telar", .sort = nullptr},
    };

    // What a row's owner column reads as: no one's, an agent's by inheritance, or owned.
    QString ownership(ProcessOwner owner) {
      if (owner == ProcessOwner::none) {
        return QStringLiteral("none");
      }

      return owner == ProcessOwner::agent_child ? QStringLiteral("inherited") : QStringLiteral("owned");
    }

    QString started(const ProcessInstance& instance) {
      return QStringLiteral("%1.%2").arg(instance.started_seconds).arg(instance.started_microseconds, static_cast<int>(microsecond_digits), decimal, QLatin1Char('0'));
    }

    template <std::size_t Capacity>
    QString text(const runtime::FixedText<Capacity>& value) {
      return toQString(value.view());
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

    QString tone(Tone value) {
      switch (value) {
      case Tone::hot:
        return QStringLiteral("hot");
      case Tone::warm:
        return QStringLiteral("warm");
      case Tone::normal:
        break;
      }

      return QStringLiteral("normal");
    }

    // The program a row names: the agent it runs when telar knows it, else the process's own name.
    std::string_view program(const monitor::ProcessRow& row) {
      if (row.agent != AgentProvider::unknown) {
        const auto name = runtime::describeProvider(row.agent).name;
        if (!name.empty()) {
          return name;
        }
      }

      return row.name.view();
    }

    std::string_view utf8(const QByteArray& bytes) {
      return {bytes.constData(), static_cast<std::size_t>(bytes.size())};
    }

    double fraction(std::uint64_t part, std::uint64_t whole) {
      return whole == 0 ? 0.0 : std::clamp(static_cast<double>(part) / static_cast<double>(whole), 0.0, 1.0);
    }

    QVariantMap meter(const QString& label, double share, const QString& value) {
      return {
          {QStringLiteral("label"), label},
          {QStringLiteral("fraction"), share},
          {QStringLiteral("value"), value},
          {QStringLiteral("tone"), tone(monitor::meterTone(share))},
      };
    }

    // "used / total" with the unit once, after both.
    QString portion(std::uint64_t used, std::uint64_t total) {
      const auto whole = monitor::bytes(total);
      const auto unit = whole.view().substr(whole.view().size() - 1);
      const auto part_text = monitor::bytes(used);
      auto part = part_text.view();

      if (part.ends_with(unit)) {
        part.remove_suffix(1);
      }

      return QStringLiteral("%1 / %2").arg(toQString(part), text(whole));
    }

    QString rate(std::uint64_t bytes_per_second) {
      return text(monitor::bytes(bytes_per_second)) + QStringLiteral("/s");
    }

    QString relative(const monitor::Relative& relative) {
      return QStringLiteral("%1 (%2)").arg(text(relative.name)).arg(relative.pid);
    }

  }

  MonitorController::MonitorController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store),
        rows_(this),
        home_(QDir::homePath()) {
    timer_.setInterval(refresh_milliseconds);
    connect(&timer_, &QTimer::timeout, this, &MonitorController::refresh);
  }

  bool MonitorController::showing() const {
    return store_.dialog().kind == Store::Dialog::monitor;
  }

  bool MonitorController::local() const {
    return store_.machines().active() == application::machines::Machines::local_slot;
  }

  bool MonitorController::available() const {
    return monitor::available(store_.session());
  }

  QAbstractItemModel* MonitorController::rows() noexcept {
    return &rows_;
  }

  void MonitorController::opened() {
    revision_ = 0;
    pending_row_ = ds::none;
    confirmation_ = ds::none;
    refresh();
    timer_.start();
    publish();
    emit changed();
  }

  void MonitorController::machineChanged() {
    if (showing()) {
      opened();
    }
  }

  void MonitorController::refresh() {
    if (!showing()) {
      timer_.stop();
      return;
    }

    monitor::refresh(store_.sessionMut());
  }

  void MonitorController::restart() {
    refresh();
    timer_.start();
    publish();
    emit changed();
  }

  void MonitorController::synchronize() {
    const auto& state = monitor::state(store_.session());
    if (state.revision == revision_) {
      return;
    }

    revision_ = state.revision;
    if (pending_row_ && selectAt(*pending_row_)) {
      pending_row_ = ds::none;
    }

    publish();
    emit changed();

    // The answer was to an older view: the view changed while it was asked, the rows shown moved
    // past it, or another process is selected.
    const auto& view = state.view;
    const auto stale_detail = view.selected.pid != 0 && (!state.detail || state.detail->process.instance.pid != view.selected.pid);

    if (state.owed || stale_detail || !monitor::covers(state)) {
      refresh();
    }
  }

  void MonitorController::publish() {
    const auto& state = monitor::state(store_.session());

    // A confirmation names one process on one machine: another selection cancels it.
    if (confirmation_ && !current(*confirmation_)) {
      confirmation_ = ds::none;
    }

    const auto& view = state.view;
    const auto groups = state.groups.view();
    const auto count = monitor::rowCount(state.matched, groups, view.layout);
    const auto end = std::min<std::size_t>(std::size_t{view.first} + view.visible, count);
    QList<QVariantMap> records;

    records.reserve(static_cast<qsizetype>(end - std::min<std::size_t>(view.first, end)));
    for (auto row = std::size_t{view.first}; row < end; ++row) {
      const auto slot = monitor::slotAt(row, groups, view.layout);

      if (slot.group) {
        records.push_back(groupRecord(groups[slot.index]));
      } else if (slot.index >= state.offset && slot.index - state.offset < state.processes.size()) {
        records.push_back(processRecord(state.processes[slot.index - state.offset]));
      } else {
        records.push_back({{QStringLiteral("kind"), QStringLiteral("pending")}, {QStringLiteral("key"), QStringLiteral("pending:%1").arg(row)}});
      }
    }

    rows_.replaceRows(std::move(records));
  }

  QVariantMap MonitorController::processRecord(const monitor::ProcessRow& row) const {
    const auto& session = store_.session();
    const auto& view = monitor::state(session).view;
    const auto cell = [&](Column column, std::string_view value, std::string_view mark = "…") {
      const auto& span = columns_[static_cast<std::size_t>(column)];

      return text(monitor::fit(value, span.cells, span.right, mark));
    };

    const auto owner = row.owner;
    const auto prefix = view.layout == MonitorLayout::tree ? monitor::treePrefix({.depth = row.depth, .guides = row.guides, .children = row.children, .folded = row.folded}) : monitor::CellText{};
    const auto name = (toQString(prefix.view()) + toQString(program(row))).toUtf8();
    const auto home = local() ? home_.toUtf8() : QByteArray{};
    const auto command = monitor::abbreviateHome(row.command.view(), utf8(home));
    const auto owner_text = monitor::ownerText(owner, monitor::ownerName(session, row.pane_id, owner).view());
    // A folded branch reads as the sum of its processes.
    const auto cpu = row.folded > 0 ? row.branch_cpu_permille : row.cpu_permille;
    const auto pid = std::to_string(row.instance.pid);
    const auto threads = std::to_string(row.threads);
    const QStringList cells{
        cell(Column::pid, pid),
        cell(Column::program, utf8(name)),
        cell(Column::command, command.view()),
        cell(Column::threads, row.measured ? std::string_view{threads} : "-"),
        cell(Column::user, row.user.view(), "+"),
        cell(Column::memory, row.measured ? monitor::bytes(row.resident_bytes).view() : "-"),
        cell(Column::cpu, row.measured ? monitor::percent(cpu).view() : "-"),
        cell(Column::owner, owner_text.view()),
    };

    return {
        {QStringLiteral("kind"), QStringLiteral("process")},
        {QStringLiteral("key"), QStringLiteral("%1:%2").arg(row.instance.pid).arg(started(row.instance))},
        {QStringLiteral("pid"), row.instance.pid},
        {QStringLiteral("started"), started(row.instance)},
        {QStringLiteral("selected"), row.instance.pid == view.selected.pid},
        {QStringLiteral("foldable"), row.children > 0},
        {QStringLiteral("folded"), row.folded > 0},
        {QStringLiteral("cells"), cells},
        {QStringLiteral("cpuTone"), row.measured ? tone(monitor::cpuTone(cpu)) : QStringLiteral("normal")},
        {QStringLiteral("owner"), ownership(owner)},
    };
  }

  QVariantMap MonitorController::groupRecord(const monitor::GroupRow& group) const {
    const auto& session = store_.session();
    const auto& cpu = columns_[static_cast<std::size_t>(Column::cpu)];
    const auto& memory = columns_[static_cast<std::size_t>(Column::memory)];
    const auto title = group.owner == ProcessOwner::none ? QStringLiteral("no owner in telar") : text(monitor::ownerText(group.owner, monitor::ownerName(session, group.pane_id, group.owner).view()));

    return {
        {QStringLiteral("kind"), QStringLiteral("group")},
        {QStringLiteral("key"), QStringLiteral("group:%1:%2").arg(static_cast<int>(group.owner)).arg(group.pane_id)},
        {QStringLiteral("title"), title},
        {QStringLiteral("count"), QStringLiteral("%1 %2").arg(group.processes).arg(group.processes == 1 ? QStringLiteral("process") : QStringLiteral("processes"))},
        {QStringLiteral("cpu"), text(monitor::fit(monitor::percent(group.cpu_permille).view(), cpu.cells, true))},
        {QStringLiteral("memory"), text(monitor::fit(monitor::bytes(group.resident_bytes).view(), memory.cells, true))},
    };
  }

  QVariantMap MonitorController::header() const {
    const auto& state = monitor::state(store_.session());
    const auto& machines = store_.machines();
    auto note = text(machines.row(machines.active()).label);

    if (state.revision != 0) {
      note += QStringLiteral(" · %1 processes · %2 threads").arg(state.process_count).arg(state.thread_count);
    } else if (available()) {
      note += QStringLiteral(" · reading the processes…");
    } else {
      note += QStringLiteral(" · this machine's runtime has no monitor; update telar there");
    }

    return {{QStringLiteral("note"), note}, {QStringLiteral("ready"), state.revision != 0}};
  }

  QVariantList MonitorController::machines() const {
    const auto& machines = store_.machines();
    const auto rows = machines.rows();
    QVariantList result;

    for (std::size_t slot = 0; slot < rows.size(); ++slot) {
      const auto& row = rows[slot];
      if (!row.used) {
        continue;
      }

      QString status;

      if (!row.live) {
        status = QStringLiteral("offline");
      } else if (row.cpu_percent) {
        status = QStringLiteral("%1 %").arg(*row.cpu_percent);
      }

      result.push_back(QVariantMap{
          {QStringLiteral("slot"), static_cast<int>(slot)},
          {QStringLiteral("label"), text(row.label)},
          {QStringLiteral("status"), status},
          {QStringLiteral("live"), row.live},
          {QStringLiteral("active"), slot == machines.active()},
      });
    }

    return result;
  }

  QVariantMap MonitorController::panels() const {
    const auto& state = monitor::state(store_.session());
    QVariantList history;
    QVariantList cores;
    QVariantList disks;
    QVariantList network;

    for (const auto share : state.cpuHistory()) {
      history.push_back(static_cast<double>(share) / decimal);
    }

    for (std::size_t core = 0; core < state.cores.size(); ++core) {
      const auto share = static_cast<double>(state.cores[core]) / monitor::MonitorLimits::whole_permille;

      cores.push_back(meter(QString::number(core), share, QStringLiteral("%1%").arg(std::lround(share * whole_percent))));
    }

    for (const auto& disk : state.disks) {
      disks.push_back(meter(text(disk.path), fraction(disk.used_bytes, disk.total_bytes), portion(disk.used_bytes, disk.total_bytes)));
    }

    // Reads and writes against the larger of the two, so the busier one fills its meter.
    const auto busiest = std::max({state.disk_read_per_second, state.disk_written_per_second, std::uint64_t{1}});

    disks.push_back(meter(QStringLiteral("read ↓"), fraction(state.disk_read_per_second, busiest), rate(state.disk_read_per_second)));
    disks.push_back(meter(QStringLiteral("written ↑"), fraction(state.disk_written_per_second, busiest), rate(state.disk_written_per_second)));

    // An interface that never carried a byte stays out, so the list keeps its shape between answers.
    std::uint64_t loudest = 1;

    for (const auto& interface : state.interfaces) {
      loudest = std::max(loudest, interface.received_per_second + interface.sent_per_second);
    }

    for (const auto& interface : state.interfaces) {
      if (interface.received_bytes == 0 && interface.sent_bytes == 0) {
        continue;
      }

      if (std::cmp_equal(network.size(), shown_interfaces)) {
        break;
      }

      const auto total = interface.received_per_second + interface.sent_per_second;

      network.push_back(meter(text(interface.name), fraction(total, loudest), QStringLiteral("↓%1 ↑%2").arg(text(monitor::bytes(interface.received_per_second)), text(monitor::bytes(interface.sent_per_second)))));
    }

    const QVariantList memory{
        meter(QStringLiteral("used"), fraction(state.memory_used_bytes, state.memory_total_bytes), portion(state.memory_used_bytes, state.memory_total_bytes)),
        meter(QStringLiteral("available"), fraction(state.memory_available_bytes, state.memory_total_bytes), text(monitor::bytes(state.memory_available_bytes))),
        meter(QStringLiteral("cached"), fraction(state.memory_cached_bytes, state.memory_total_bytes), text(monitor::bytes(state.memory_cached_bytes))),
        meter(QStringLiteral("swap"), fraction(state.swap_used_bytes, state.swap_total_bytes), portion(state.swap_used_bytes, state.swap_total_bytes)),
    };

    return {
        {QStringLiteral("cpu"), text(monitor::percent(state.cpu_permille)) + QStringLiteral(" %")},
        {QStringLiteral("history"), history},
        {QStringLiteral("cores"), cores},
        {QStringLiteral("memoryTotal"), text(monitor::bytes(state.memory_total_bytes))},
        {QStringLiteral("memory"), memory},
        {QStringLiteral("disks"), disks},
        {QStringLiteral("network"), network},
    };
  }

  QVariantMap MonitorController::view() const {
    const auto& state = monitor::state(store_.session());
    const auto& view = state.view;

    return {
        {QStringLiteral("sort"), QString::fromLatin1(sort_names[static_cast<std::size_t>(view.sort)])},
        {QStringLiteral("reverse"), view.reverse},
        {QStringLiteral("scope"), QString::fromLatin1(scope_names[static_cast<std::size_t>(view.scope)])},
        {QStringLiteral("layout"), QString::fromLatin1(layout_names[static_cast<std::size_t>(view.layout)])},
        {QStringLiteral("filter"), text(view.filter)},
        {QStringLiteral("selected"), view.selected.pid},
        {QStringLiteral("all"), state.process_count},
        {QStringLiteral("telar"), state.telar_count},
        {QStringLiteral("agents"), state.agent_count},
    };
  }

  QVariantList MonitorController::columns() const {
    const auto& view = monitor::state(store_.session()).view;
    QVariantList result;

    for (std::size_t index = 0; index < monitor::column_count; ++index) {
      const auto& span = columns_[index];
      const auto& title = titles[index];
      const auto sorted = title.sort != nullptr && QLatin1StringView{title.sort} == QLatin1StringView{sort_names[static_cast<std::size_t>(view.sort)]};
      const auto label = sorted ? QStringLiteral("%1 %2").arg(QLatin1StringView{title.title}, view.reverse ? QStringLiteral("▲") : QStringLiteral("▼")) : QString::fromLatin1(title.title);
      const auto bytes = label.toUtf8();

      result.push_back(QVariantMap{
          {QStringLiteral("x"), span.start * cell_width_},
          {QStringLiteral("width"), span.cells * cell_width_},
          {QStringLiteral("title"), text(monitor::fit(utf8(bytes), span.cells, span.right))},
          {QStringLiteral("sort"), title.sort == nullptr ? QString{} : QString::fromLatin1(title.sort)},
          {QStringLiteral("sorted"), sorted},
          {QStringLiteral("owner"), title.column == Column::owner},
      });
    }

    return result;
  }

  QVariantMap MonitorController::detail() const {
    const auto& session = store_.session();
    const auto& state = monitor::state(session);
    if (!state.detail || state.view.selected.pid == 0) {
      return {};
    }

    const auto& detail = *state.detail;
    const auto& process = detail.process;
    const auto kept = detail.keptChildren();
    QStringList ports;
    QStringList lineage;
    QStringList children;

    for (std::size_t index = 0; index < detail.port_count; ++index) {
      ports.push_back(QString::number(detail.ports[index]));
    }

    // The parent first: the nearest ancestors say the most, so a narrow detail cuts the root's end.
    for (const auto& ancestor : std::views::reverse(detail.keptLineage())) {
      if (std::cmp_equal(lineage.size(), shown_lineage)) {
        lineage.push_back(QStringLiteral("…"));
        break;
      }

      lineage.push_back(relative(ancestor));
    }

    for (const auto& child : kept.first(std::min(kept.size(), shown_children))) {
      children.push_back(relative(child));
    }

    if (detail.child_count > shown_children) {
      children.push_back(QStringLiteral("+%1 more").arg(detail.child_count - shown_children));
    }

    const auto home = local() ? home_.toUtf8() : QByteArray{};
    const auto owner = monitor::ownerText(process.owner, monitor::ownerName(session, process.pane_id, process.owner).view());

    return {
        {QStringLiteral("pid"), process.instance.pid},
        {QStringLiteral("program"), toQString(program(process))},
        {QStringLiteral("state"), QString::fromLatin1(state_names[static_cast<std::size_t>(process.state)])},
        {QStringLiteral("stopped"), process.state == monitor::ProcessState::stopped},
        {QStringLiteral("nice"), process.nice},
        {QStringLiteral("user"), text(process.user)},
        {QStringLiteral("arguments"), text(monitor::abbreviateHome(detail.arguments.view(), utf8(home)))},
        {QStringLiteral("directory"), text(monitor::abbreviateHome(detail.directory.view(), utf8(home)))},
        {QStringLiteral("ports"), ports.isEmpty() ? QStringLiteral("none") : ports.join(QStringLiteral(", "))},
        {QStringLiteral("usage"), process.measured ? QStringLiteral("%1 threads · %2").arg(process.threads).arg(text(monitor::bytes(process.resident_bytes))) : QStringLiteral("not readable by this user")},
        {QStringLiteral("owner"), process.owner == ProcessOwner::none ? QStringLiteral("none: telar did not start it") : text(owner)},
        {QStringLiteral("pane"), process.pane_id != 0},
        {QStringLiteral("lineage"), lineage.isEmpty() ? QStringLiteral("none") : lineage.join(QStringLiteral(" ← "))},
        {QStringLiteral("children"), children.isEmpty() ? QStringLiteral("none") : children.join(QStringLiteral(", "))},
    };
  }

  QVariantMap MonitorController::footer() const {
    const auto& state = monitor::state(store_.session());
    const auto& view = state.view;
    const auto count = monitor::rowCount(state.matched, state.groups.view(), view.layout);
    const auto last = std::min<std::size_t>(std::size_t{view.first} + view.visible, count);
    const auto noun = view.layout == MonitorLayout::owner ? QStringLiteral("rows") : QStringLiteral("processes");

    return {
        {QStringLiteral("count"), count == 0 ? QStringLiteral("no %1").arg(noun) : QStringLiteral("%1–%2 of %3 %4").arg(view.first + 1).arg(last).arg(count).arg(noun)},
        {QStringLiteral("position"), count == 0 ? 0.0 : static_cast<double>(view.first) / static_cast<double>(count)},
        {QStringLiteral("size"), count == 0 ? 1.0 : std::min(1.0, static_cast<double>(view.visible) / static_cast<double>(count))},
    };
  }

  QString MonitorController::error() const {
    return text(monitor::state(store_.session()).error);
  }

  bool MonitorController::selected() const {
    return monitor::state(store_.session()).view.selected.pid != 0;
  }

  void MonitorController::setTable(QSizeF area, QSizeF cell) {
    // A cell's width the table already uses, within what rounding moves it.
    constexpr qreal same_width = 1e-3;

    if (cell.width() <= 0 || cell.height() <= 0) {
      return;
    }

    auto& view = monitor::view(store_.sessionMut());
    const auto cells = static_cast<std::uint16_t>(std::clamp(area.width() / cell.width(), 0.0, static_cast<qreal>(std::numeric_limits<std::uint16_t>::max())));
    const auto visible = static_cast<std::uint16_t>(std::clamp(area.height() / cell.height(), 0.0, static_cast<qreal>(monitor::MonitorLimits::maximum_processes)));
    if (cells == cells_ && std::abs(cell.width() - cell_width_) < same_width && visible == view.visible) {
      return;
    }

    cells_ = cells;
    cell_width_ = cell.width();
    columns_ = monitor::columns(cells, view.layout);
    view.visible = visible;
    if (showing()) {
      restart();
    }
  }

  void MonitorController::reveal(std::size_t row) {
    auto& view = monitor::view(store_.sessionMut());

    if (row < view.first) {
      view.first = static_cast<std::uint32_t>(row);
    } else if (view.visible > 0 && row >= std::size_t{view.first} + view.visible) {
      view.first = static_cast<std::uint32_t>(row - view.visible + 1);
    }
  }

  void MonitorController::scroll(int delta) {
    const auto& state = monitor::state(store_.session());
    const auto count = monitor::rowCount(state.matched, state.groups.view(), state.view.layout);
    const auto last_first = count > state.view.visible ? count - state.view.visible : 0;
    const auto first = std::clamp<std::int64_t>(std::int64_t{state.view.first} + delta, 0, static_cast<std::int64_t>(last_first));
    if (std::cmp_equal(first, state.view.first)) {
      return;
    }

    monitor::view(store_.sessionMut()).first = static_cast<std::uint32_t>(first);
    publish();
    emit changed();
    if (!monitor::covers(monitor::state(store_.session()))) {
      refresh();
    }
  }

  ds::Option<std::size_t> MonitorController::selectedRow() const {
    const auto& state = monitor::state(store_.session());
    const auto pid = state.view.selected.pid;
    if (pid == 0) {
      return ds::none;
    }

    for (std::size_t index = 0; index < state.processes.size(); ++index) {
      if (state.processes[index].instance.pid == pid) {
        return monitor::rowOf(state.offset + index, state.groups.view(), state.view.layout);
      }
    }

    return ds::none;
  }

  bool MonitorController::selectAt(std::size_t row) {
    const auto& state = monitor::state(store_.session());
    const auto slot = monitor::slotAt(row, state.groups.view(), state.view.layout);
    if (slot.group || slot.index < state.offset || slot.index - state.offset >= state.processes.size()) {
      return false;
    }

    // A copy: the view below lives in the same session.
    const auto instance = state.processes[slot.index - state.offset].instance;

    monitor::view(store_.sessionMut()).selected = instance;
    return true;
  }

  void MonitorController::move(int delta) {
    const auto& state = monitor::state(store_.session());
    const auto& view = state.view;
    const auto count = monitor::rowCount(state.matched, state.groups.view(), view.layout);
    if (count == 0 || delta == 0) {
      return;
    }

    // From the selected row, or from just outside the rows shown on the side the move comes from.
    const auto outside = delta > 0 ? std::int64_t{view.first} - 1 : std::int64_t{view.first} + view.visible;
    const auto from = selectedRow() ? static_cast<std::int64_t>(*selectedRow()) : outside;
    auto row = static_cast<std::size_t>(std::clamp<std::int64_t>(from + delta, 0, static_cast<std::int64_t>(count - 1)));

    // A group's title is passed over in the move's direction.
    while (monitor::slotAt(row, state.groups.view(), view.layout).group) {
      if (delta > 0 ? row + 1 >= count : row == 0) {
        break;
      }

      row = delta > 0 ? row + 1 : row - 1;
    }

    reveal(row);
    pending_row_ = ds::none;
    if (!selectAt(row)) {
      pending_row_ = row;
    }

    restart();
  }

  void MonitorController::selectRow(int index) {
    const auto first = monitor::state(store_.session()).view.first;

    if (index < 0) {
      return;
    }

    if (selectAt(std::size_t{first} + static_cast<std::size_t>(index))) {
      pending_row_ = ds::none;
      restart();
    }
  }

  void MonitorController::clearSelection() {
    monitor::view(store_.sessionMut()).selected = {};
    pending_row_ = ds::none;
    restart();
  }

  void MonitorController::setSort(const QString& sort) {
    if (const auto index = indexOf(sort_names, sort)) {
      auto& view = monitor::relist(monitor::view(store_.sessionMut()));
      const auto chosen = static_cast<MonitorSort>(*index);

      view.reverse = view.sort == chosen && !view.reverse;
      view.sort = chosen;
      view.first = 0;
      restart();
    }
  }

  void MonitorController::cycleSort() {
    auto& view = monitor::relist(monitor::view(store_.sessionMut()));
    const auto* const found = std::ranges::find(sort_cycle, view.sort);
    const auto next = (static_cast<std::size_t>(found - sort_cycle.begin()) + 1) % sort_cycle.size();

    view.sort = sort_cycle[next];
    view.reverse = false;
    view.first = 0;
    restart();
  }

  void MonitorController::toggleReverse() {
    auto& view = monitor::relist(monitor::view(store_.sessionMut()));

    view.reverse = !view.reverse;
    view.first = 0;
    restart();
  }

  void MonitorController::setScope(const QString& scope) {
    if (const auto index = indexOf(scope_names, scope)) {
      auto& view = monitor::relist(monitor::view(store_.sessionMut()));

      view.scope = static_cast<MonitorScope>(*index);
      view.first = 0;
      restart();
    }
  }

  void MonitorController::setLayout(const QString& layout) {
    auto& view = monitor::view(store_.sessionMut());
    const auto index = indexOf(layout_names, layout);
    if (!index || static_cast<MonitorLayout>(*index) == view.layout) {
      return;
    }

    monitor::relist(view).layout = static_cast<MonitorLayout>(*index);
    view.first = 0;
    columns_ = monitor::columns(cells_, view.layout);
    restart();
  }

  void MonitorController::toggleTree() {
    const auto tree = monitor::state(store_.session()).view.layout == MonitorLayout::tree;

    setLayout(QString::fromLatin1(layout_names[static_cast<std::size_t>(tree ? MonitorLayout::flat : MonitorLayout::tree)]));
  }

  void MonitorController::setFilter(const QString& filter) {
    auto& view = monitor::view(store_.sessionMut());
    const auto bytes = filter.toUtf8();
    const auto kept = runtime::utf8Prefix(utf8(bytes), monitor::MonitorLimits::filter_bytes);
    if (kept == view.filter.view()) {
      return;
    }

    monitor::relist(view).filter.assign(kept);
    view.first = 0;
    restart();
  }

  void MonitorController::toggleFold(int pid) {
    if (pid <= 0) {
      return;
    }

    monitor::toggle(monitor::view(store_.sessionMut()), pid);
    restart();
  }

  void MonitorController::foldSelected(bool folded) {
    const auto& state = monitor::state(store_.session());
    if (state.view.layout != MonitorLayout::tree) {
      return;
    }

    for (const auto& row : state.processes) {
      if (row.instance.pid == state.view.selected.pid && row.children > 0 && (row.folded > 0) != folded) {
        toggleFold(row.instance.pid);
        return;
      }
    }
  }

  void MonitorController::signal(const QString& name) {
    static constexpr ds::Array<const char*, 2> names{"STOP", "CONT"};
    static constexpr ds::Array<ProcessSignal, 2> kinds{ProcessSignal::stop, ProcessSignal::resume};
    // A copy: the call below changes the session the view lives in.
    const auto chosen = monitor::state(store_.session()).view.selected;
    const auto index = indexOf(names, name);
    if (!index || chosen.pid == 0) {
      return;
    }

    send(chosen, kinds[*index]);
  }

  void MonitorController::send(const ProcessInstance& process, ProcessSignal signal) {
    if (!monitor::signal(store_.sessionMut(), process, signal)) {
      emit failed(QStringLiteral("The monitor is busy with another request; try again"));
    }
  }

  void MonitorController::ask(const QString& action) {
    const auto& machines = store_.machines();
    const auto selected = monitor::state(store_.session()).view.selected;
    const auto index = indexOf(confirmable_names, action);
    if (!index || selected.pid == 0) {
      return;
    }

    confirmation_.emplace(Confirmation{
        .action = static_cast<Confirmable>(*index),
        .process = selected,
        .machine = machines.token(machines.active()),
        .target = target(selected),
    });

    emit changed();
  }

  void MonitorController::confirm() {
    if (!confirmation_) {
      return;
    }

    const auto asked = *confirmation_;

    confirmation_ = ds::none;
    emit changed();
    if (!showing() || !current(asked)) {
      return;
    }

    switch (asked.action) {
    case Confirmable::terminate:
      send(asked.process, ProcessSignal::terminate);
      break;
    case Confirmable::kill:
      send(asked.process, ProcessSignal::kill);
      break;
    case Confirmable::debug:
      launch(asked.process, QStringLiteral("debug"));
      break;
    }
  }

  void MonitorController::cancel() {
    if (confirmation_) {
      confirmation_ = ds::none;
      emit changed();
    }
  }

  bool MonitorController::current(const Confirmation& confirmation) const {
    const auto& machines = store_.machines();

    return monitor::state(store_.session()).view.selected == confirmation.process && machines.token(machines.active()) == confirmation.machine;
  }

  QString MonitorController::target(const ProcessInstance& process) const {
    const auto& state = monitor::state(store_.session());
    const auto named = [&](const monitor::ProcessRow& row) {
      return QStringLiteral("%1 (%2)").arg(toQString(program(row))).arg(process.pid);
    };

    for (const auto& row : state.processes) {
      if (row.instance == process) {
        return named(row);
      }
    }

    if (state.detail && state.detail->process.instance == process) {
      return named(state.detail->process);
    }

    return QStringLiteral("pid %1").arg(process.pid);
  }

  QVariantMap MonitorController::confirmation() const {
    if (!confirmation_) {
      return {};
    }

    return {
        {QStringLiteral("action"), QString::fromLatin1(confirmable_names[static_cast<std::size_t>(confirmation_->action)])},
        {QStringLiteral("target"), confirmation_->target},
    };
  }

  void MonitorController::renice(int nice) {
    const auto chosen = monitor::state(store_.session()).view.selected;
    if (chosen.pid == 0) {
      return;
    }

    if (!monitor::prioritize(store_.sessionMut(), chosen, std::clamp(nice, least_nice, most_nice))) {
      emit failed(QStringLiteral("The monitor is busy with another request; try again"));
    }
  }

  void MonitorController::copyCommand() {
    const auto& state = monitor::state(store_.session());
    if (state.detail && state.view.selected.pid != 0) {
      QGuiApplication::clipboard()->setText(text(state.detail->arguments));
    }
  }

  void MonitorController::focusPane() {
    const auto& state = monitor::state(store_.session());
    if (!state.detail || state.detail->process.pane_id == 0) {
      emit failed(QStringLiteral("This process runs in no telar pane"));
      return;
    }

    const auto pane = state.detail->process.pane_id;

    emit closeRequested();
    application::workbench::focusPane(store_.sessionMut(), pane);
  }

  void MonitorController::review(const QString& tool) {
    static constexpr ds::Array<const char*, 3> tools{"stack", "files", "logs"};
    const auto selected = monitor::state(store_.session()).view.selected;
    if (!indexOf(tools, tool) || selected.pid == 0) {
      return;
    }

    launch(selected, tool);
  }

  void MonitorController::launch(const ProcessInstance& process, const QString& tool) {
    const auto* focused = store_.session().focusedPane();
    if (focused == nullptr) {
      return;
    }

    // The new pane runs on the process's machine: its `telar` checks the instance again, runs the
    // tool, then leaves a shell.
    const auto script = QStringLiteral("\"${TELAR_BIN_PATH:-telar}\" process review %1 --started %2 --tool %3; exec \"${SHELL:-/bin/sh}\" -l").arg(process.pid).arg(started(process), tool).toUtf8();
    const ds::Array<std::string_view, 3> arguments{"/bin/sh", "-c", utf8(script)};
    const auto pane = focused->id;

    emit closeRequested();
    try {
      application::workbench::launchSplit(store_.sessionMut(), pane, arguments);
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }
  }

  void MonitorController::selectMachine(int slot) {
    const auto& machines = store_.machines();
    const auto rows = machines.rows();
    if (slot < 0 || static_cast<std::size_t>(slot) >= rows.size() || !rows[static_cast<std::size_t>(slot)].used) {
      return;
    }

    const auto chosen = static_cast<application::machines::Machines::Slot>(slot);
    if (chosen != machines.active()) {
      emit machineRequested(machines.token(chosen));
    }
  }

  bool MonitorController::perform(window_actions::Action action) {
    using window_actions::Action;

    if (!selected()) {
      return false;
    }

    switch (action) {
    // As with the monitor's own keys, TERM and KILL wait there for a yes.
    case Action::process_terminate:
      ask(QStringLiteral("TERM"));
      return true;
    case Action::process_kill:
      ask(QStringLiteral("KILL"));
      return true;
    case Action::process_stop:
      signal(QStringLiteral("STOP"));
      return true;
    case Action::process_continue:
      signal(QStringLiteral("CONT"));
      return true;
    case Action::process_lower_priority: {
      constexpr int step = 5;
      const auto& state = monitor::state(store_.session());

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

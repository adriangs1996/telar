module telar.gui.features.monitor;

import std;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.text.utf8;
import telar.wire.monitor;

namespace telar::gui::features::monitor {
  namespace {

    template <std::size_t Capacity>
    void copy(FixedText<Capacity>& output, std::string_view text) {
      output.assign(runtime::utf8Prefix(text, Capacity));
    }

    ProcessRow row(const MonitorProcess& process) {
      ProcessRow result{
          .instance = process.instance,
          .parent = process.parent,
          .user_id = process.user_id,
          .state = process.state,
          .measured = process.measured,
          .cpu_permille = process.cpu_permille,
          .resident_bytes = process.resident_bytes,
          .threads = process.threads,
          .nice = process.nice,
          .pane_id = process.pane_id,
          .agent = process.agent,
          .owner = process.owner,
          .depth = process.depth,
          .guides = process.guides,
          .children = process.children,
          .folded = process.folded,
          .branch_cpu_permille = process.branch_cpu_permille,
      };

      copy(result.user, process.user);
      copy(result.name, process.name);
      copy(result.command, process.command);
      return result;
    }

    template <std::size_t Size>
    std::uint8_t keep(ds::Array<Relative, Size>& kept, std::span<const MonitorRelative> relatives) {
      const auto count = std::min(relatives.size(), Size);

      for (std::size_t index = 0; index < count; ++index) {
        kept.atMut(index).pid = relatives[index].pid;
        copy(kept.atMut(index).name, relatives[index].name);
      }

      return static_cast<std::uint8_t>(count);
    }

    // The highest rate of a reading: of the interfaces the panel shows, and of the disks.
    void rememberPeaks(State& state, bool in_a_row) noexcept {
      ds::Array<std::uint8_t, shown_interfaces> shown{};
      std::uint64_t loudest = 0;

      // Readings the window missed leave rates it never saw: the peaks start again.
      if (!in_a_row) {
        state.network_peaks = {};
        state.disk_peaks = {};
      }

      for (const auto index : shown.view().first(shownInterfaces(state.interfaces.view(), shown.viewMut()))) {
        const auto& interface = state.interfaces[index];

        loudest = std::max(loudest, interface.received_per_second + interface.sent_per_second);
      }

      state.network_peaks.push(loudest);
      state.disk_peaks.push(std::max(state.disk_read_per_second, state.disk_written_per_second));
    }

  }

  void RatePeaks::push(std::uint64_t rate) noexcept {
    if (count == values.size()) {
      std::ranges::copy(values.view().subspan(1), values.dataMut());
      --count;
    }

    values.atMut(count++) = rate;
  }

  std::uint64_t RatePeaks::scale(std::uint64_t floor) const noexcept {
    return std::ranges::fold_left(values.view().first(count), floor, [](std::uint64_t highest, std::uint64_t value) {
      return std::max(highest, value);
    });
  }

  std::size_t shownInterfaces(std::span<const InterfaceRow> interfaces, std::span<std::uint8_t> shown) noexcept {
    const auto carried = [](const InterfaceRow& interface) {
      return interface.received_bytes + interface.sent_bytes;
    };

    const auto busy = [](const InterfaceRow& interface) {
      return interface.received_per_second + interface.sent_per_second > 0;
    };

    std::size_t count = 0;

    for (std::size_t index = 0; index < interfaces.size() && index <= std::numeric_limits<std::uint8_t>::max(); ++index) {
      const auto& interface = interfaces[index];
      if (carried(interface) == 0) {
        continue;
      }

      // Insertion into the few kept: the busy first, then by bytes carried.
      const auto before = [&](std::uint8_t kept) {
        const auto& other = interfaces[kept];

        return busy(interface) != busy(other) ? busy(interface) : carried(interface) > carried(other);
      };

      const auto kept = shown.first(count);
      const auto position = static_cast<std::size_t>(std::ranges::find_if(kept, before) - kept.begin());
      if (position == shown.size()) {
        continue;
      }

      count = std::min(count + 1, shown.size());
      std::ranges::shift_right(shown.first(count).subspan(position), 1);
      shown[position] = static_cast<std::uint8_t>(index);
    }

    return count;
  }

  std::span<const Relative> ProcessDetail::keptChildren() const noexcept {
    return children.view().first(std::min<std::size_t>(child_count, kept_relatives));
  }

  std::span<const Relative> ProcessDetail::keptLineage() const noexcept {
    return lineage.view().first(lineage_count);
  }

  std::span<const std::int32_t> View::toggledPids() const noexcept {
    return toggled.view().first(toggled_count);
  }

  void toggle(View& view, std::int32_t pid) noexcept {
    const auto pids = relist(view).toggled.viewMut().first(view.toggled_count);

    if (const auto found = std::ranges::find(pids, pid); found != pids.end()) {
      std::ranges::copy(std::next(found), pids.end(), found);
      --view.toggled_count;
      return;
    }

    if (view.toggled_count == view.toggled.size()) {
      std::ranges::copy(pids.subspan(1), pids.begin());
      --view.toggled_count;
    }

    view.toggled.atMut(view.toggled_count++) = pid;
  }

  View& relist(View& view) noexcept {
    ++view.listing;
    return view;
  }

  State::State(Memory& memory)
      : cores(memory),
        disks(memory),
        interfaces(memory),
        processes(memory),
        groups(memory) {}

  std::span<const std::uint16_t> State::cpuHistory() const noexcept {
    return history.view().first(history_count);
  }

  const ProcessDetail* selectedDetail(const State& state) noexcept {
    const auto& selected = state.view.selected;
    if (selected.pid == 0 || !state.detail || state.detail->process.instance != selected) {
      return nullptr;
    }

    return &*state.detail;
  }

  Window window(const State& state) noexcept {
    return windowAround(state.view.first, state.view.visible, state.groups.view(), state.view.layout);
  }

  bool covers(const State& state) noexcept {
    const auto& view = state.view;
    const auto rows = rowCount(state.matched, state.groups.view(), view.layout);
    const auto end = std::min<std::size_t>(std::size_t{view.first} + view.visible, rows);
    const auto held_end = std::size_t{state.offset} + state.processes.size();

    for (auto row = std::size_t{view.first}; row < end; ++row) {
      const auto slot = slotAt(row, state.groups.view(), view.layout);
      if (!slot.group && (slot.index < state.offset || slot.index >= held_end)) {
        return false;
      }
    }

    return true;
  }

  QueryMonitor query(const State& state) noexcept {
    const auto asked = window(state);

    return {
        .sections = MonitorSections::all,
        .sort = state.view.sort,
        .reverse = state.view.reverse,
        .scope = state.view.scope,
        .layout = state.view.layout,
        .filter = state.view.filter.view(),
        .offset = asked.offset,
        .limit = asked.limit,
        .fold = true,
        .toggled = state.view.toggledPids(),
        .detail = state.view.selected,
    };
  }

  void wait(State& state, std::uint64_t request_id) noexcept {
    state.waiting = request_id;
    state.asked_offset = window(state).offset;
    state.asked_listing = state.view.listing;
    state.owed = false;
  }

  bool receive(State& state, const MonitorSnapshot& snapshot) {
    if (state.waiting == 0 || snapshot.request_id != state.waiting) {
      return false;
    }

    state.waiting = 0;
    state.error.assign({});
    state.cpu_permille = snapshot.cpu_permille;

    const auto reading = snapshot.sample != state.sample;
    const auto in_a_row = state.sample != 0 && snapshot.sample == state.sample + 1;

    state.sample = snapshot.sample;
    // The runtime keeps the history, so the window shows the same one however often it opens.
    if ((snapshot.sections & MonitorSections::host) != 0) {
      state.history_count = static_cast<std::uint8_t>(std::min(snapshot.history.size(), history_samples));
      std::ranges::copy(snapshot.history.last(state.history_count), state.history.dataMut());
    }

    state.cores.clear();
    state.cores.extend(snapshot.cores);
    state.memory_total_bytes = snapshot.memory_total_bytes;
    state.memory_used_bytes = snapshot.memory_used_bytes;
    state.memory_available_bytes = snapshot.memory_available_bytes;
    state.memory_cached_bytes = snapshot.memory_cached_bytes;
    state.swap_total_bytes = snapshot.swap_total_bytes;
    state.swap_used_bytes = snapshot.swap_used_bytes;
    state.process_count = snapshot.process_count;
    state.telar_count = snapshot.telar_count;
    state.agent_count = snapshot.agent_count;
    state.agents = snapshot.agents;
    state.thread_count = snapshot.thread_count;
    state.unmeasured_count = snapshot.unmeasured_count;
    state.unattributed_cpu_permille = snapshot.unattributed_cpu_permille;
    state.user_id = snapshot.user_id;
    state.disk_read_per_second = snapshot.disk_read_per_second;
    state.disk_written_per_second = snapshot.disk_written_per_second;
    state.disks.clear();
    for (const auto& disk : snapshot.disks) {
      auto& kept = state.disks.push(DiskRow{.total_bytes = disk.total_bytes, .used_bytes = disk.used_bytes, .available_bytes = disk.available_bytes});

      copy(kept.path, disk.path);
      copy(kept.type, disk.type);
    }

    state.interfaces.clear();
    for (const auto& interface : snapshot.interfaces) {
      auto& kept = state.interfaces.push(InterfaceRow{
          .received_per_second = interface.received_per_second,
          .sent_per_second = interface.sent_per_second,
          .received_bytes = interface.received_bytes,
          .sent_bytes = interface.sent_bytes,
      });

      copy(kept.name, interface.name);
    }

    if (reading) {
      rememberPeaks(state, in_a_row);
    }

    // Rows of a listing the view left are not shown: the query for the current one goes next.
    if (state.asked_listing != state.view.listing) {
      state.owed = true;
    } else {
      state.matched = snapshot.matched;
      state.offset = state.asked_offset;
      state.processes.clear();
      state.processes.reserve(snapshot.processes.size());
      for (const auto& process : snapshot.processes) {
        state.processes.push(row(process));
      }

      state.groups.clear();
      for (const auto& group : snapshot.groups) {
        state.groups.push(GroupRow{.owner = group.owner, .pane_id = group.pane_id, .processes = group.processes, .cpu_permille = group.cpu_permille, .resident_bytes = group.resident_bytes});
      }

      // A listing that got shorter keeps its last screen full.
      const auto rows = rowCount(state.matched, state.groups.view(), state.view.layout);

      if (std::size_t{state.view.first} + state.view.visible > rows) {
        state.view.first = static_cast<std::uint32_t>(rows > state.view.visible ? rows - state.view.visible : 0);
      }
    }

    state.detail.reset();
    if (snapshot.detail) {
      auto& detail = state.detail.emplace();

      detail.process = row(snapshot.detail->process);
      copy(detail.arguments, snapshot.detail->arguments);
      copy(detail.directory, snapshot.detail->directory);
      detail.port_count = static_cast<std::uint8_t>(std::min(snapshot.detail->ports.size(), max_listed_ports));
      std::ranges::copy(snapshot.detail->ports.first(detail.port_count), detail.ports.dataMut());
      detail.child_count = static_cast<std::uint16_t>(snapshot.detail->children.size());
      static_cast<void>(keep(detail.children, snapshot.detail->children));
      detail.lineage_count = keep(detail.lineage, snapshot.detail->lineage);
    }

    ++state.revision;
    return true;
  }

  bool fail(State& state, std::uint64_t request_id, std::string_view message) {
    if (request_id == 0 || (request_id != state.waiting && request_id != state.acting)) {
      return false;
    }

    // A selected process that is gone is no longer asked about.
    if (request_id == state.waiting) {
      state.waiting = 0;
      state.view.selected = {};
    } else {
      state.acting = 0;
    }

    copy(state.error, message);
    ++state.revision;
    return true;
  }

  bool complete(State& state, std::uint64_t request_id) {
    if (request_id == 0 || request_id != state.acting) {
      return false;
    }

    state.acting = 0;
    state.error.assign({});
    ++state.revision;
    return true;
  }

  void reset(State& state) noexcept {
    state.waiting = 0;
    state.acting = 0;
    state.owed = false;
    // A new runtime counts its readings from the start.
    state.sample = 0;
  }

}

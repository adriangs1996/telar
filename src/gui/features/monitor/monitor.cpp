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
          .depth = process.depth,
      };

      copy(result.user, process.user);
      copy(result.name, process.name);
      copy(result.command, process.command);
      return result;
    }

  }

  State::State(Memory& memory)
      : cores(memory),
        disks(memory),
        interfaces(memory),
        processes(memory) {}

  QueryMonitor ask(State& state, std::uint64_t request_id) noexcept {
    state.waiting = request_id;

    return {
        .request_id = request_id,
        .sections = MonitorSections::all,
        .sort = state.view.sort,
        .reverse = state.view.reverse,
        .scope = state.view.scope,
        .tree = state.view.tree,
        .filter = state.view.filter.view(),
        .limit = View::rows,
        .detail = state.view.selected,
    };
  }

  bool receive(State& state, const MonitorSnapshot& snapshot) {
    if (state.waiting == 0 || snapshot.request_id != state.waiting) {
      return false;
    }

    state.waiting = 0;
    state.error.assign({});
    state.cpu_permille = snapshot.cpu_permille;
    state.cores.clear();
    state.cores.extend(snapshot.cores);
    state.memory_total_bytes = snapshot.memory_total_bytes;
    state.memory_used_bytes = snapshot.memory_used_bytes;
    state.memory_available_bytes = snapshot.memory_available_bytes;
    state.memory_cached_bytes = snapshot.memory_cached_bytes;
    state.swap_total_bytes = snapshot.swap_total_bytes;
    state.swap_used_bytes = snapshot.swap_used_bytes;
    state.process_count = snapshot.process_count;
    state.thread_count = snapshot.thread_count;
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
      auto& kept = state.interfaces.push(InterfaceRow{.received_per_second = interface.received_per_second, .sent_per_second = interface.sent_per_second});

      copy(kept.name, interface.name);
    }

    state.matched = snapshot.matched;
    state.processes.clear();
    state.processes.reserve(snapshot.processes.size());
    for (const auto& process : snapshot.processes) {
      state.processes.push(row(process));
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
  }

}

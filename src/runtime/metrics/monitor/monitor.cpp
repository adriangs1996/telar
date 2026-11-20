module telar.runtime.metrics.monitor;

import std;
import telar.sys.posix;

import telar.runtime.platform.host_metrics;
import telar.runtime.platform.process_probe;
import telar.runtime.platform.process_table;
import telar.config.runtime;
import telar.wire.monitor;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.text.utf8;
import telar.base.ds;

namespace telar::runtime {
  namespace {

    constexpr std::size_t maximum_cached_users = 256;
    constexpr std::size_t user_record_bytes = 4096;
    constexpr double nanoseconds_per_second = 1e9;
    constexpr std::uint32_t permille = 1000;

    // Text a process chose, such as its arguments, made fit for display: control bytes become spaces,
    // and bytes that are not UTF-8 become question marks.
    template <std::size_t Capacity>
    void displayCopy(FixedText<Capacity>& output, std::string_view text) noexcept {
      ds::Array<char, Capacity> bytes;
      const auto length = std::min(text.size(), Capacity);

      for (std::size_t index = 0; index < length; ++index) {
        const auto byte = static_cast<unsigned char>(text[index]);

        bytes.atMut(index) = byte < 0x20 || byte == 0x7f ? ' ' : static_cast<char>(byte);
      }

      const auto valid = inspectUtf8(utf8Prefix({bytes.data(), length}, Capacity)) == Utf8Validation::valid;
      if (!valid) {
        for (std::size_t index = 0; index < length; ++index) {
          if (static_cast<unsigned char>(bytes[index]) >= 0x80) {
            bytes.atMut(index) = '?';
          }
        }
      }

      output.assign(utf8Prefix({bytes.data(), length}, Capacity));
    }

    std::uint64_t ratePerSecond(std::uint64_t now, std::uint64_t before, double seconds) noexcept {
      if (seconds <= 0 || now < before) {
        return 0;
      }

      return static_cast<std::uint64_t>(static_cast<double>(now - before) / seconds);
    }

    std::uint16_t busyPermille(std::uint64_t busy, std::uint64_t total) noexcept {
      if (total == 0) {
        return 0;
      }

      return static_cast<std::uint16_t>(std::min<std::uint64_t>(busy * permille / total, permille));
    }

    bool sameInstance(const ProcessRecord& left, const ProcessRecord& right) noexcept {
      return left.pid == right.pid && left.started_seconds == right.started_seconds && left.started_microseconds == right.started_microseconds;
    }

    FixedText<MonitorLimits::user_bytes> userName(ds::Vec<UserName, ConcurrentMemory>& users, uid_t user) {
      for (const auto& known : users) {
        if (known.user == user) {
          return known.name;
        }
      }

      UserName found{.user = user};
      passwd record{};
      passwd* result = nullptr;
      ds::Array<char, user_record_bytes> storage;
      if (::getpwuid_r(user, &record, storage.dataMut(), storage.size(), &result) == 0 && result != nullptr && result->pw_name != nullptr) {
        displayCopy(found.name, std::string_view{result->pw_name});
      } else {
        ds::Array<char, 16> digits;
        const auto converted = std::to_chars(digits.dataMut(), digits.dataMut() + digits.size(), user);

        found.name.assign({digits.data(), static_cast<std::size_t>(converted.ptr - digits.data())});
      }

      if (users.size() < maximum_cached_users) {
        users.push(found);
      }

      return found.name;
    }

    void describe(MonitorEntry& entry, const ProcessInspector& inspector, ds::Vec<UserName, ConcurrentMemory>& users) {
      ds::Array<char, MonitorLimits::command_bytes> text;
      const auto line = inspector.commandLine(entry.record.pid, text.viewMut());
      const auto first = line.text.substr(0, line.text.find(' '));
      const auto program = processBasename(first);
      const auto short_name = entry.record.name.view();

      entry.agent = line.provider;
      displayCopy(entry.command, line.text);
      // macOS keeps 16 bytes of a process's name; its program's file name is the whole of it.
      displayCopy(entry.name, !short_name.empty() && program.size() > short_name.size() && program.starts_with(short_name) ? program : short_name);
      entry.user = userName(users, entry.record.user);
      entry.described = true;
    }

    MonitorProcess row(const MonitorEntry& entry, std::uint8_t depth) noexcept {
      return {
          .instance = {.pid = entry.record.pid, .started_seconds = entry.record.started_seconds, .started_microseconds = entry.record.started_microseconds},
          .parent = std::max(entry.record.parent, 0),
          .user_id = entry.record.user,
          .user = entry.user.view(),
          .name = entry.name.view(),
          .command = entry.command.view(),
          .state = entry.record.state,
          .measured = entry.record.measured,
          .cpu_permille = entry.cpu_permille,
          .resident_bytes = entry.record.resident_bytes,
          .threads = entry.record.threads,
          .nice = entry.record.nice,
          .pane_id = entry.pane_id,
          .agent = entry.agent,
          .depth = depth,
      };
    }
  }

  MonitorSampler::MonitorSampler(ConcurrentMemory& memory, const ProcessInspector& inspector)
      : memory_(memory),
        inspector_(inspector),
        entries_(memory),
        previous_(memory),
        users_(memory),
        selected_(memory),
        depths_(memory),
        ordered_(memory),
        flags_(memory),
        stack_(memory),
        rows_(memory),
        details_(memory) {}

  void MonitorSampler::update(ds::Vec<ProcessRecord, ConcurrentMemory>& records, const HostDetail& host, Clock::time_point now, std::span<const PaneRoot> roots) {
    const auto seconds = sampled_ ? std::chrono::duration<double>(now - *sampled_).count() : 0.0;

    std::ranges::sort(records.viewMut(), {}, &ProcessRecord::pid);
    std::swap(previous_, entries_);
    entries_.clear();
    entries_.reserve(records.size());
    thread_count_ = 0;

    std::size_t earlier = 0;

    for (const auto& record : records) {
      while (earlier < previous_.size() && previous_[earlier].record.pid < record.pid) {
        ++earlier;
      }

      auto& entry = entries_.push(MonitorEntry{.record = record});

      if (earlier < previous_.size() && sameInstance(previous_[earlier].record, record)) {
        const auto& before = previous_[earlier];

        entry.agent = before.agent;
        entry.described = before.described;
        entry.name = before.name;
        entry.user = before.user;
        entry.command = before.command;
        if (record.measured && before.record.measured && seconds > 0 && record.cpu_nanoseconds >= before.record.cpu_nanoseconds) {
          const auto share = static_cast<double>(record.cpu_nanoseconds - before.record.cpu_nanoseconds) / (seconds * nanoseconds_per_second);

          entry.cpu_permille = static_cast<std::uint32_t>(std::min(share * permille, static_cast<double>(std::numeric_limits<std::uint32_t>::max())));
        }
      }

      if (!entry.described) {
        describe(entry, inspector_, users_);
      }

      thread_count_ += record.threads;
    }

    records.clear();
    attribute(roots);
    measureHost(host, seconds);
    sampled_ = now;
    readings_ = std::min<std::uint32_t>(readings_ + 1, 2);
  }

  bool MonitorSampler::ready() const noexcept {
    return readings_ >= 2;
  }

  std::span<const MonitorEntry> MonitorSampler::entries() const noexcept {
    return entries_.view();
  }

  ds::Option<std::uint32_t> MonitorSampler::indexOf(pid_t process) const noexcept {
    const auto* const found = std::ranges::lower_bound(entries_, process, {}, [](const MonitorEntry& entry) {
      return entry.record.pid;
    });
    if (found == entries_.end() || found->record.pid != process) {
      return ds::none;
    }

    return static_cast<std::uint32_t>(found - entries_.begin());
  }

  const MonitorEntry* MonitorSampler::find(const ProcessInstance& instance) const noexcept {
    const auto index = indexOf(instance.pid);
    if (!index) {
      return nullptr;
    }

    const auto& entry = entries_[*index];
    const auto any = instance.started_seconds == 0 && instance.started_microseconds == 0;
    if (!any && (entry.record.started_seconds != instance.started_seconds || entry.record.started_microseconds != instance.started_microseconds)) {
      return nullptr;
    }

    return &entry;
  }

  // Which pane each process runs in and whether an agent runs it, from the parents in the table: a
  // process belongs to the pane whose shell it descends from.
  void MonitorSampler::attribute(std::span<const PaneRoot> roots) {
    constexpr std::uint8_t unresolved = 0;
    constexpr std::uint8_t visiting = 1;
    constexpr std::uint8_t resolved = 2;

    flags_.clear();
    flags_.resize(entries_.size(), unresolved);
    for (const auto& root : roots) {
      if (const auto index = indexOf(root.process)) {
        auto& entry = entries_.atMut(*index);

        entry.pane_id = root.pane_id;
        entry.under_agent = entry.agent != AgentProvider::unknown;
        flags_.atMut(*index) = resolved;
      }
    }

    for (std::uint32_t start = 0; start < entries_.size(); ++start) {
      std::uint64_t pane = 0;
      bool agent = false;
      auto index = start;

      ordered_.clear();
      while (flags_[index] == unresolved) {
        flags_.atMut(index) = visiting;
        ordered_.push(index);

        const auto parent = indexOf(entries_[index].record.parent);
        if (!parent || *parent == index) {
          break;
        }

        index = *parent;
      }

      if (flags_[index] == resolved) {
        pane = entries_[index].pane_id;
        agent = entries_[index].under_agent;
      }

      for (auto chain = ordered_.size(); chain-- > 0;) {
        auto& entry = entries_.atMut(ordered_[chain]);

        agent = agent || entry.agent != AgentProvider::unknown;
        entry.pane_id = pane;
        entry.under_agent = agent;
        flags_.atMut(ordered_[chain]) = resolved;
      }
    }
  }

  void MonitorSampler::measureHost(const HostDetail& host, double seconds) {
    ds::Array<std::uint64_t, HostDetail::maximum_interfaces> received{};
    ds::Array<std::uint64_t, HostDetail::maximum_interfaces> sent{};
    std::uint64_t busy = 0;
    std::uint64_t total = 0;

    for (std::size_t core = 0; core < host.core_count; ++core) {
      const auto& now = host.cores[core];
      const auto known = seconds > 0 && core < host_.core_count && now.total >= host_.cores[core].total && now.busy >= host_.cores[core].busy;
      const auto core_busy = known ? now.busy - host_.cores[core].busy : 0;
      const auto core_total = known ? now.total - host_.cores[core].total : 0;

      cores_.atMut(core) = busyPermille(core_busy, core_total);
      busy += core_busy;
      total += core_total;
    }

    cpu_permille_ = busyPermille(busy, total);
    disk_read_per_second_ = ratePerSecond(host.disk_read_bytes, host_.disk_read_bytes, seconds);
    disk_written_per_second_ = ratePerSecond(host.disk_written_bytes, host_.disk_written_bytes, seconds);
    for (std::size_t index = 0; index < host.interface_count; ++index) {
      const auto& now = host.interfaces[index];

      for (std::size_t earlier = 0; earlier < host_.interface_count; ++earlier) {
        if (host_.interfaces[earlier].name == now.name) {
          received.atMut(index) = ratePerSecond(now.received_bytes, host_.interfaces[earlier].received_bytes, seconds);
          sent.atMut(index) = ratePerSecond(now.sent_bytes, host_.interfaces[earlier].sent_bytes, seconds);
        }
      }
    }

    host_ = host;
    for (std::size_t index = 0; index < host_.interface_count; ++index) {
      const auto& counters = host_.interfaces[index];

      interfaces_.atMut(index) = {
          .name = counters.name.view(),
          .received_per_second = received[index],
          .sent_per_second = sent[index],
          .received_bytes = counters.received_bytes,
          .sent_bytes = counters.sent_bytes,
      };
    }

    for (std::size_t index = 0; index < host_.mount_count; ++index) {
      const auto& mount = host_.mounts[index];

      disks_.atMut(index) = {
          .path = mount.path.view(),
          .device = mount.device.view(),
          .type = mount.type.view(),
          .total_bytes = mount.total_bytes,
          .used_bytes = mount.used_bytes,
          .available_bytes = mount.available_bytes,
      };
    }
  }

  bool MonitorSampler::matches(const MonitorEntry& entry, const MonitorView& view) const noexcept {
    if ((view.scope == MonitorScope::telar && entry.pane_id == 0) || (view.scope == MonitorScope::agents && !entry.under_agent)) {
      return false;
    }

    const auto filter = view.filter.view();
    if (filter.empty()) {
      return true;
    }

    ds::Array<char, 16> digits;
    const auto converted = std::to_chars(digits.dataMut(), digits.dataMut() + digits.size(), entry.record.pid);
    const std::string_view pid{digits.data(), static_cast<std::size_t>(converted.ptr - digits.data())};

    return pid == filter || containsInsensitive(entry.name.view(), filter) || containsInsensitive(entry.command.view(), filter) || containsInsensitive(entry.user.view(), filter);
  }

  bool MonitorSampler::before(const MonitorEntry& left, const MonitorEntry& right, const MonitorView& view) const noexcept {
    // Larger first for amounts, smaller first for names and pids; reverse flips either.
    const auto order = [&](auto first, auto second, bool descending) {
      if (first == second) {
        return left.record.pid < right.record.pid;
      }

      return (descending ? first > second : first < second) != view.reverse;
    };

    switch (view.sort) {
    case MonitorSort::cpu:
      return order(left.cpu_permille, right.cpu_permille, true);
    case MonitorSort::memory:
      return order(left.record.resident_bytes, right.record.resident_bytes, true);
    case MonitorSort::threads:
      return order(left.record.threads, right.record.threads, true);
    case MonitorSort::pid:
      return order(left.record.pid, right.record.pid, false);
    case MonitorSort::name:
      return order(left.name.view(), right.name.view(), false);
    }

    return left.record.pid < right.record.pid;
  }

  void MonitorSampler::select(const MonitorView& view) {
    selected_.clear();
    ordered_.clear();
    depths_.clear();
    for (std::uint32_t index = 0; index < entries_.size(); ++index) {
      if (matches(entries_[index], view)) {
        selected_.push(index);
      }
    }

    if (view.tree) {
      selectTree(view);
      return;
    }

    const auto count = std::min<std::size_t>(view.limit, selected_.size());
    const auto less = [&](std::uint32_t left, std::uint32_t right) {
      return before(entries_[left], entries_[right], view);
    };

    std::ranges::partial_sort(selected_.viewMut(), selected_.viewMut().begin() + static_cast<std::ptrdiff_t>(count), less);
    for (std::size_t index = 0; index < count; ++index) {
      ordered_.push(selected_[index]);
      depths_.push(0);
    }
  }

  // Each selected process under its selected parent, siblings in the query's order; a process
  // whose parent is not selected starts a tree of its own.
  void MonitorSampler::selectTree(const MonitorView& view) {
    constexpr std::size_t deepest = std::numeric_limits<std::uint8_t>::max();
    const auto parentOf = [&](std::uint32_t index) {
      return entries_[index].record.parent;
    };

    std::ranges::sort(selected_.viewMut(), [&](std::uint32_t left, std::uint32_t right) {
      const auto left_parent = parentOf(left);
      const auto right_parent = parentOf(right);

      return left_parent != right_parent ? left_parent < right_parent : before(entries_[left], entries_[right], view);
    });

    flags_.clear();
    flags_.resize(entries_.size(), 0);
    for (const auto index : selected_) {
      flags_.atMut(index) = 1;
    }

    stack_.clear();
    // Roots in reverse order, so the first is taken first.
    for (auto position = selected_.size(); position-- > 0;) {
      const auto index = selected_[position];
      const auto parent = indexOf(parentOf(index));
      if (!parent || *parent == index || flags_[*parent] == 0) {
        stack_.push({index, 0});
      }
    }

    std::ranges::sort(stack_.viewMut(), [&](const auto& left, const auto& right) {
      return before(entries_[right.first], entries_[left.first], view);
    });

    while (!stack_.empty() && ordered_.size() < view.limit) {
      const auto [index, depth] = *stack_.pop();
      const auto pid = entries_[index].record.pid;

      ordered_.push(index);
      depths_.push(depth);

      const auto children = std::ranges::equal_range(selected_, pid, {}, parentOf);

      for (const auto* child = children.end(); child != children.begin();) {
        --child;
        if (*child != index) {
          stack_.push({*child, static_cast<std::uint8_t>(std::min<std::size_t>(depth + 1u, deepest))});
        }
      }
    }
  }

  MonitorAnswers MonitorSampler::answer(std::span<const MonitorView> views) {
    // Where each query's rows and detail are; every row and detail is written before any answer
    // views them.
    struct Written {
      bool found = true;
      std::size_t first = 0;
      std::size_t count = 0;
      std::uint32_t matched = 0;
      ds::Option<std::size_t> detail;
    };

    const auto queries = std::min(views.size(), maximum_answers);
    ds::Array<Written, maximum_answers> written{};
    std::size_t rows = 0;

    for (std::size_t query = 0; query < queries; ++query) {
      rows += views[query].limit;
    }

    rows_.clear();
    details_.clear();
    rows_.reserve(rows);
    details_.reserve(queries);
    for (std::size_t query = 0; query < queries; ++query) {
      const auto& view = views[query];
      auto& place = written.atMut(query);

      if (view.detail.pid != 0) {
        place.found = detail(view.detail);
        if (!place.found) {
          continue;
        }

        place.detail = details_.size() - 1;
      }

      if ((view.sections & MonitorSections::processes) != 0) {
        select(view);
        place.first = rows_.size();
        place.count = std::min(ordered_.size(), rows_.capacity() - place.first);
        place.matched = static_cast<std::uint32_t>(selected_.size());
        for (std::size_t index = 0; index < place.count; ++index) {
          rows_.push(row(entries_[ordered_[index]], depths_[index]));
        }
      }
    }

    MonitorAnswers answers{};

    for (std::size_t query = 0; query < queries; ++query) {
      const auto& view = views[query];
      const auto& place = written[query];
      if (!place.found) {
        continue;
      }

      auto& snapshot = answers.atMut(query).emplace();

      snapshot.sections = view.sections;
      if ((view.sections & MonitorSections::host) != 0) {
        snapshot.cpu_permille = cpu_permille_;
        snapshot.cores = {cores_.data(), host_.core_count};
        snapshot.memory_total_bytes = host_.memory_total_bytes;
        snapshot.memory_used_bytes = host_.memory_used_bytes;
        snapshot.memory_available_bytes = host_.memory_available_bytes;
        snapshot.memory_cached_bytes = host_.memory_cached_bytes;
        snapshot.swap_total_bytes = host_.swap_total_bytes;
        snapshot.swap_used_bytes = host_.swap_used_bytes;
        snapshot.process_count = static_cast<std::uint32_t>(entries_.size());
        snapshot.thread_count = thread_count_;
      }

      if ((view.sections & MonitorSections::disks) != 0) {
        snapshot.disks = {disks_.data(), host_.mount_count};
        snapshot.disk_read_per_second = disk_read_per_second_;
        snapshot.disk_written_per_second = disk_written_per_second_;
      }

      if ((view.sections & MonitorSections::network) != 0) {
        snapshot.interfaces = {interfaces_.data(), host_.interface_count};
      }

      if ((view.sections & MonitorSections::processes) != 0) {
        snapshot.matched = place.matched;
        snapshot.processes = rows_.view().subspan(place.first, place.count);
      }

      if (place.detail) {
        const auto& text = details_[*place.detail];
        const auto& entry = text.entry ? entries_[*text.entry] : text.fresh;

        snapshot.detail = MonitorDetail{
            .process = row(entry, 0),
            .arguments = text.arguments.view(),
            .directory = text.directory.view(),
            .ports = text.ports.view(),
            .children = {text.children.data(), text.child_count},
        };
      }
    }

    return answers;
  }

  // Reads the detail of the instance into a new DetailText; false when it is gone or was replaced.
  bool MonitorSampler::detail(const ProcessInstance& instance) {
    // The process as it is now: the last reading may still list one that exited since.
    const auto record = ProcessTable::find(instance.pid);
    const auto any = instance.started_seconds == 0 && instance.started_microseconds == 0;
    if (!record || (!any && (record->started_seconds != instance.started_seconds || record->started_microseconds != instance.started_microseconds))) {
      return false;
    }

    auto& text = details_.push(DetailText{});
    const auto index = indexOf(record->pid);
    const auto listed = index && sameInstance(entries_[*index].record, *record);
    ds::Array<char, MonitorLimits::arguments_bytes> arguments;
    const auto pid = record->pid;

    if (listed) {
      text.entry = *index;
    } else {
      // Started after the last reading: described now, with the pane and agent of its parent.
      text.fresh.record = *record;
      describe(text.fresh, inspector_, users_);
      if (const auto parent = indexOf(record->parent)) {
        text.fresh.pane_id = entries_[*parent].pane_id;
        text.fresh.under_agent = entries_[*parent].under_agent || text.fresh.agent != AgentProvider::unknown;
      }
    }

    displayCopy(text.arguments, inspector_.commandLine(pid, arguments.viewMut()).text);
    displayCopy(text.directory, inspector_.directory(pid).view());
    if (const auto identity = inspector_.identity(pid)) {
      text.ports = inspector_.listeningPorts(identity->process_group);
    }

    for (const auto& entry : entries_) {
      if (entry.record.parent == pid && entry.record.pid != pid && text.child_count < MonitorLimits::maximum_children) {
        text.children.atMut(text.child_count++) = entry.record.pid;
      }
    }

    return true;
  }

}

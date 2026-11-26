module telar.runtime.metrics.monitor;

import std;
import telar.sys.posix;

import telar.runtime.host.host_metrics;
import telar.runtime.host.process_probe;
import telar.runtime.host.process_table;
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

    // The control bytes below the space and DEL, and the first byte past ASCII.
    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char delete_byte = 0x7f;
    constexpr unsigned char first_non_ascii = 0x80;

    // Room for a process or user id in decimal.
    constexpr std::size_t id_digits = 16;

    // Text a process chose, such as its arguments, made fit for display: control bytes become spaces,
    // and bytes that are not UTF-8 become question marks.
    template <std::size_t Capacity>
    void displayCopy(FixedText<Capacity>& output, std::string_view text) noexcept { // NOLINT(bugprone-exception-escape): assign throws only past its capacity, and the text is cut to it
      ds::Array<char, Capacity> bytes{};
      const auto length = std::min(text.size(), Capacity);

      for (std::size_t index = 0; index < length; ++index) {
        const auto byte = static_cast<unsigned char>(text[index]);

        bytes.atMut(index) = byte < first_printable || byte == delete_byte ? ' ' : static_cast<char>(byte);
      }

      const auto valid = inspectUtf8(utf8Prefix({bytes.data(), length}, Capacity)) == Utf8Validation::valid;
      if (!valid) {
        for (std::size_t index = 0; index < length; ++index) {
          if (static_cast<unsigned char>(bytes[index]) >= first_non_ascii) {
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
      ds::Array<char, user_record_bytes> storage{};
      if (::getpwuid_r(user, &record, storage.dataMut(), storage.size(), &result) == 0 && result != nullptr && result->pw_name != nullptr) {
        displayCopy(found.name, std::string_view{result->pw_name});
      } else {
        ds::Array<char, id_digits> digits{};
        const auto converted = std::to_chars(digits.dataMut(), std::to_address(digits.viewMut().end()), user);

        found.name.assign({digits.data(), static_cast<std::size_t>(converted.ptr - digits.data())});
      }

      if (users.size() < maximum_cached_users) {
        users.push(found);
      }

      return found.name;
    }

    void describe(MonitorEntry& entry, const ProcessInspector& inspector, ds::Vec<UserName, ConcurrentMemory>& users) {
      ds::Array<char, MonitorLimits::command_bytes> text{};
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

    // What a process is to telar, from where it runs and what runs it: `telar` names the runtime's
    // own processes.
    ProcessOwner ownerOf(const MonitorEntry& entry, std::span<const pid_t> telar) noexcept {
      if (std::ranges::contains(telar, entry.record.pid)) {
        return ProcessOwner::telar;
      }

      if (entry.pane_id == 0) {
        return ProcessOwner::none;
      }

      if (entry.agent != AgentProvider::unknown) {
        return ProcessOwner::agent;
      }

      return entry.under_agent ? ProcessOwner::agent_child : ProcessOwner::pane;
    }

    bool underAgent(ProcessOwner owner) noexcept {
      return owner == ProcessOwner::agent || owner == ProcessOwner::agent_child;
    }

    std::uint32_t saturated(std::uint64_t value) noexcept {
      return static_cast<std::uint32_t>(std::min<std::uint64_t>(value, std::numeric_limits<std::uint32_t>::max()));
    }

  }

  bool MonitorView::toggles(std::int32_t pid) const noexcept {
    return std::ranges::contains(toggled.view().first(toggled_count), pid);
  }

  MonitorProcess MonitorSampler::row(const MonitorEntry& entry, const Listed& listed) const noexcept {
    MonitorProcess result{
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
        .owner = entry.owner,
        .depth = listed.depth,
        .guides = listed.guides,
        .folded = listed.folded,
        .branch_cpu_permille = entry.cpu_permille,
    };

    if (listed.index < branches_.size()) {
      const auto& branch = branches_[listed.index];

      result.children = branch.children;
      result.branch_cpu_permille = saturated(branch.cpu_permille);
    }

    return result;
  }

  MonitorSampler::MonitorSampler(ConcurrentMemory& memory, const ProcessInspector& inspector)
      : memory_(memory),
        inspector_(inspector),
        entries_(memory),
        previous_(memory),
        users_(memory),
        selected_(memory),
        listed_(memory),
        ordered_(memory),
        flags_(memory),
        stack_(memory),
        branches_(memory),
        group_of_(memory),
        rows_(memory),
        groups_(memory),
        details_(memory),
        self_(::getpid()) {
    clients_.atMut(0) = self_;
  }

  void MonitorSampler::update(ds::Vec<ProcessRecord, ConcurrentMemory>& records, const HostDetail& host, Clock::time_point now, std::span<const PaneRoot> roots, std::span<const pid_t> clients) {
    const auto seconds = sampled_ ? std::chrono::duration<double>(now - *sampled_).count() : 0.0;

    // The runtime first, then as many clients as fit.
    clients_.atMut(0) = self_;
    client_count_ = 1 + std::min(clients.size(), clients_.size() - 1);
    std::ranges::copy(clients.first(client_count_ - 1), clients_.viewMut().subspan(1).begin());

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
    ++sample_;
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

    telar_count_ = 0;
    agent_count_ = 0;
    for (auto& entry : entries_.viewMut()) {
      entry.owner = ownerOf(entry, clients_.view().first(client_count_));
      telar_count_ += entry.owner != ProcessOwner::none ? 1U : 0U;
      agent_count_ += underAgent(entry.owner) ? 1U : 0U;
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

  bool MonitorSampler::matches(const MonitorEntry& entry, const MonitorView& view) noexcept {
    if ((view.scope == MonitorScope::telar && entry.owner == ProcessOwner::none) || (view.scope == MonitorScope::agents && !underAgent(entry.owner))) {
      return false;
    }

    const auto filter = view.filter.view();
    if (filter.empty()) {
      return true;
    }

    ds::Array<char, id_digits> digits{};
    const auto converted = std::to_chars(digits.dataMut(), std::to_address(digits.viewMut().end()), entry.record.pid);
    const std::string_view pid{digits.data(), static_cast<std::size_t>(converted.ptr - digits.data())};

    return pid == filter || containsInsensitive(entry.name.view(), filter) || containsInsensitive(entry.command.view(), filter) || containsInsensitive(entry.user.view(), filter);
  }

  bool MonitorSampler::before(const MonitorEntry& left, const MonitorEntry& right, const MonitorView& view) noexcept {
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

  bool MonitorSampler::beforeBranch(std::uint32_t left, std::uint32_t right, const MonitorView& view) const noexcept {
    const auto& left_branch = branches_[left];
    const auto& right_branch = branches_[right];
    const auto order = [&](auto first, auto second) {
      if (first == second) {
        return entries_[left].record.pid < entries_[right].record.pid;
      }

      return (first > second) != view.reverse;
    };

    switch (view.sort) {
    case MonitorSort::cpu:
      return order(left_branch.cpu_permille, right_branch.cpu_permille);
    case MonitorSort::memory:
      return order(left_branch.resident_bytes, right_branch.resident_bytes);
    case MonitorSort::threads:
    case MonitorSort::pid:
    case MonitorSort::name:
      break;
    }

    return before(entries_[left], entries_[right], view);
  }

  bool MonitorSampler::folds(const Listed& listed, const MonitorView& view) const noexcept {
    const auto& branch = branches_[listed.index];
    if (branch.children == 0) {
      return false;
    }

    // A tree's roots stay open: folding one would fold most of the listing.
    const auto folded = view.fold && listed.depth > 0 && branch.children > MonitorLimits::folded_children;

    return folded != view.toggles(entries_[listed.index].record.pid);
  }

  // The listing of one query in listed_: every row, so that matched counts them; the answer takes the
  // rows of its window.
  void MonitorSampler::select(const MonitorView& view) {
    selected_.clear();
    listed_.clear();
    branches_.clear();
    for (std::uint32_t index = 0; index < entries_.size(); ++index) {
      if (matches(entries_[index], view)) {
        selected_.push(index);
      }
    }

    if (view.layout == MonitorLayout::tree) {
      selectTree(view);
      return;
    }

    if (view.layout == MonitorLayout::owner) {
      selectOwners(view);
      return;
    }

    // Only the rows up to the window's end need their order.
    const auto count = std::min<std::size_t>(std::size_t{view.offset} + view.limit, selected_.size());
    const auto less = [&](std::uint32_t left, std::uint32_t right) {
      return before(entries_[left], entries_[right], view);
    };

    std::ranges::partial_sort(selected_.viewMut(), selected_.viewMut().begin() + static_cast<std::ptrdiff_t>(count), less);
    for (std::size_t index = 0; index < count; ++index) {
      listed_.push({.index = selected_[index]});
    }
  }

  // Each selected process under its selected parent; a process whose parent is not selected starts
  // a tree of its own. Siblings go in the query's order of their branches, and a folded branch lists
  // its first process alone.
  ds::Option<std::uint32_t> MonitorSampler::selectedParent(std::uint32_t index) const noexcept {
    const auto parent = indexOf(entries_[index].record.parent);
    if (!parent || *parent == index || flags_[*parent] == 0) {
      return ds::none;
    }

    return *parent;
  }

  // Each branch's sums: every process goes before its parent in ordered_, then they add up from the
  // last. selected_ is sorted by parent.
  void MonitorSampler::sumBranches() {
    const auto parent_of = [&](std::uint32_t index) {
      return entries_[index].record.parent;
    };

    branches_.clear();
    branches_.resize(entries_.size(), Branch{});
    ordered_.clear();
    stack_.clear();
    for (const auto index : selected_) {
      if (!selectedParent(index)) {
        stack_.push({.index = index});
      }
    }

    while (!stack_.empty()) {
      const auto index = stack_.pop()->index;

      ordered_.push(index);
      for (const auto child : std::ranges::equal_range(selected_, entries_[index].record.pid, {}, parent_of)) {
        if (child != index) {
          stack_.push({.index = child});
        }
      }
    }

    for (auto position = ordered_.size(); position-- > 0;) {
      const auto index = ordered_[position];
      auto& branch = branches_.atMut(index);

      branch.cpu_permille += entries_[index].cpu_permille;
      branch.resident_bytes += entries_[index].record.resident_bytes;
      if (const auto parent = selectedParent(index)) {
        auto& above = branches_.atMut(*parent);

        above.cpu_permille += branch.cpu_permille;
        above.resident_bytes += branch.resident_bytes;
        above.descendants += branch.descendants + 1;
        above.children = static_cast<std::uint16_t>(std::min<std::uint32_t>(above.children + 1U, std::numeric_limits<std::uint16_t>::max()));
      }
    }
  }

  // Pushes the children of `listed` last first, so the first is taken first; every child but the
  // last has a sibling after it, which its guides say.
  void MonitorSampler::pushChildren(const Listed& listed) {
    constexpr std::size_t deepest = std::numeric_limits<std::uint8_t>::max();
    const auto parent_of = [&](std::uint32_t index) {
      return entries_[index].record.parent;
    };

    const auto children = std::ranges::equal_range(selected_, entries_[listed.index].record.pid, {}, parent_of);
    const auto depth = static_cast<std::uint8_t>(std::min<std::size_t>(listed.depth + 1U, deepest));
    const auto continues = listed.depth < MonitorLimits::guide_levels ? std::uint32_t{1} << listed.depth : 0;
    bool last = true;

    for (const auto child : std::views::reverse(children)) {
      if (child == listed.index) {
        continue;
      }

      stack_.push({.index = child, .depth = depth, .guides = last ? listed.guides : listed.guides | continues});
      last = false;
    }
  }

  // Each selected process under its selected parent; a process whose parent is not selected starts
  // a tree of its own. Siblings go in the query's order of their branches, and a folded branch lists
  // its first process alone.
  void MonitorSampler::selectTree(const MonitorView& view) {
    const auto parent_of = [&](std::uint32_t index) {
      return entries_[index].record.parent;
    };

    flags_.clear();
    flags_.resize(entries_.size(), 0);
    for (const auto index : selected_) {
      flags_.atMut(index) = 1;
    }

    std::ranges::sort(selected_.viewMut(), {}, parent_of);
    sumBranches();

    // Siblings in the query's order: sorted by parent, then by branch.
    std::ranges::sort(selected_.viewMut(), [&](std::uint32_t left, std::uint32_t right) {
      const auto left_parent = parent_of(left);
      const auto right_parent = parent_of(right);

      return left_parent != right_parent ? left_parent < right_parent : beforeBranch(left, right, view);
    });

    stack_.clear();
    for (const auto index : selected_) {
      if (!selectedParent(index)) {
        stack_.push({.index = index});
      }
    }

    // Roots in reverse order, so the first is taken first.
    std::ranges::sort(stack_.viewMut(), [&](const Listed& left, const Listed& right) {
      return beforeBranch(right.index, left.index, view);
    });

    while (!stack_.empty()) {
      auto listed = *stack_.pop();

      if (folds(listed, view)) {
        listed.folded = branches_[listed.index].descendants;
        listed_.push(listed);
        continue;
      }

      listed_.push(listed);
      pushChildren(listed);
    }
  }

  // Adds up the selected processes of each owner into groups_ from `first`: one group for each pane,
  // one for telar's and one for those of no pane. group_of_ says each process's group.
  void MonitorSampler::groupOwners(std::size_t first) {
    // A pane's group is an agent's once any of its processes is one.
    const auto group_owner = [](ProcessOwner owner) {
      return owner == ProcessOwner::agent || owner == ProcessOwner::agent_child ? ProcessOwner::pane : owner;
    };

    group_of_.clear();
    group_of_.resize(entries_.size(), no_group);
    for (const auto index : selected_) {
      const auto& entry = entries_[index];
      const auto owner = group_owner(entry.owner);
      const auto pane = owner == ProcessOwner::pane ? entry.pane_id : 0;
      const auto groups = groups_.view().subspan(first);
      const auto found = std::ranges::find_if(groups, [&](const MonitorGroup& group) {
        return group_owner(group.owner) == owner && group.pane_id == pane;
      });

      const auto position = static_cast<std::size_t>(found - groups.begin());

      if (found == groups.end() && groups.size() == MonitorLimits::maximum_groups) {
        continue;
      }

      if (found == groups.end()) {
        groups_.push({.owner = owner, .pane_id = pane});
      }

      auto& group = groups_.atMut(first + position);

      group.owner = underAgent(entry.owner) ? ProcessOwner::agent : group.owner;
      ++group.processes;
      group.cpu_permille = saturated(std::uint64_t{group.cpu_permille} + entry.cpu_permille);
      group.resident_bytes += entry.record.resident_bytes;
      group_of_.atMut(index) = static_cast<std::uint16_t>(position);
    }
  }

  // The processes of each pane together, then telar's, then those of no pane: a pane's group goes
  // before the others in the query's order of its processor share, and the processes of a group in
  // the query's order.
  void MonitorSampler::selectOwners(const MonitorView& view) {
    const auto first = groups_.size();

    groupOwners(first);

    const auto groups = groups_.viewMut().subspan(first);
    const auto group_before = [&](const MonitorGroup& left, const MonitorGroup& right) {
      const auto left_none = left.owner == ProcessOwner::none;
      const auto right_none = right.owner == ProcessOwner::none;
      if (left_none != right_none) {
        return right_none;
      }

      if (left.cpu_permille != right.cpu_permille) {
        return (left.cpu_permille > right.cpu_permille) != view.reverse;
      }

      return left.pane_id < right.pane_id;
    };

    // Each group's rank in the listing, by its index before the sort.
    ds::Array<std::uint16_t, MonitorLimits::maximum_groups> rank{};
    ds::Array<std::uint16_t, MonitorLimits::maximum_groups> order{};

    std::ranges::iota(order.viewMut().first(groups.size()), std::uint16_t{0});
    std::ranges::sort(order.viewMut().first(groups.size()), [&](std::uint16_t left, std::uint16_t right) {
      return group_before(groups[left], groups[right]);
    });

    for (std::size_t position = 0; position < groups.size(); ++position) {
      rank.atMut(order[position]) = static_cast<std::uint16_t>(position);
    }

    std::ranges::sort(groups, group_before);

    // A process past the last group the reply carries is left out of the listing.
    static_cast<void>(selected_.retain([&](std::uint32_t index) {
      return group_of_[index] != no_group;
    }));

    std::ranges::sort(selected_.viewMut(), [&](std::uint32_t left, std::uint32_t right) {
      const auto left_rank = rank[group_of_[left]];
      const auto right_rank = rank[group_of_[right]];

      return left_rank != right_rank ? left_rank < right_rank : before(entries_[left], entries_[right], view);
    });

    for (const auto index : selected_) {
      listed_.push({.index = index});
    }
  }

  MonitorAnswers MonitorSampler::answer(std::span<const MonitorView> views) {
    const auto queries = std::min(views.size(), maximum_answers);
    const auto written = place(views.first(queries));
    MonitorAnswers answers{};

    for (std::size_t query = 0; query < queries; ++query) {
      const auto& view = views[query];
      const auto& placement = written[query];
      if (!placement.found) {
        continue;
      }

      auto& snapshot = answers.atMut(query).emplace();

      snapshot.sections = view.sections;
      snapshot.sample = sample_;
      if ((view.sections & MonitorSections::host) != 0) {
        snapshot.cpu_permille = cpu_permille_;
        snapshot.cores = cores_.view().first(host_.core_count);
        snapshot.memory_total_bytes = host_.memory_total_bytes;
        snapshot.memory_used_bytes = host_.memory_used_bytes;
        snapshot.memory_available_bytes = host_.memory_available_bytes;
        snapshot.memory_cached_bytes = host_.memory_cached_bytes;
        snapshot.swap_total_bytes = host_.swap_total_bytes;
        snapshot.swap_used_bytes = host_.swap_used_bytes;
        snapshot.process_count = static_cast<std::uint32_t>(entries_.size());
        snapshot.telar_count = telar_count_;
        snapshot.agent_count = agent_count_;
        snapshot.thread_count = thread_count_;
      }

      if ((view.sections & MonitorSections::disks) != 0) {
        snapshot.disks = disks_.view().first(host_.mount_count);
        snapshot.disk_read_per_second = disk_read_per_second_;
        snapshot.disk_written_per_second = disk_written_per_second_;
      }

      if ((view.sections & MonitorSections::network) != 0) {
        snapshot.interfaces = interfaces_.view().first(host_.interface_count);
      }

      if ((view.sections & MonitorSections::processes) != 0) {
        snapshot.matched = placement.matched;
        snapshot.processes = rows_.view().subspan(placement.first, placement.count);
        snapshot.groups = groups_.view().subspan(placement.first_group, placement.group_count);
      }

      if (placement.detail) {
        const auto& text = details_[*placement.detail];
        const auto& entry = text.entry ? entries_[*text.entry] : text.fresh;

        snapshot.detail = MonitorDetail{
            .process = row(entry, Listed{.index = std::numeric_limits<std::uint32_t>::max()}),
            .arguments = text.arguments.view(),
            .directory = text.directory.view(),
            .ports = text.ports.view(),
            .children = {text.children.data(), text.child_count},
            .lineage = {text.lineage.data(), text.lineage_count},
        };
      }
    }

    return answers;
  }

  // Every row and detail is written before any answer views them.
  auto MonitorSampler::place(std::span<const MonitorView> views) -> Placements {
    Placements written{};
    std::size_t rows = 0;

    for (const auto& view : views) {
      rows += view.limit;
    }

    rows_.clear();
    groups_.clear();
    details_.clear();
    rows_.reserve(rows);
    details_.reserve(views.size());
    for (std::size_t query = 0; query < views.size(); ++query) {
      const auto& view = views[query];
      auto& placement = written.atMut(query);

      if (view.detail.pid != 0) {
        placement.found = detail(view.detail);
        if (!placement.found) {
          continue;
        }

        placement.detail = details_.size() - 1;
      }

      if ((view.sections & MonitorSections::processes) != 0) {
        placement.first_group = groups_.size();
        select(view);
        placement.group_count = groups_.size() - placement.first_group;

        const auto first = std::min<std::size_t>(view.offset, listed_.size());

        placement.first = rows_.size();
        placement.count = std::min({listed_.size() - first, std::size_t{view.limit}, rows_.capacity() - placement.first});
        placement.matched = static_cast<std::uint32_t>(view.layout == MonitorLayout::flat ? selected_.size() : listed_.size());
        for (std::size_t index = 0; index < placement.count; ++index) {
          const auto& listed = listed_[first + index];

          rows_.push(row(entries_[listed.index], listed));
        }
      }
    }

    return written;
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
    ds::Array<char, MonitorLimits::arguments_bytes> arguments{};
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

      text.fresh.owner = ownerOf(text.fresh, clients_.view().first(client_count_));
    }

    displayCopy(text.arguments, inspector_.quotedArguments(pid, arguments.viewMut()));
    displayCopy(text.directory, inspector_.directory(pid).view());
    if (const auto identity = inspector_.identity(pid)) {
      text.ports = inspector_.listeningPorts(identity->process_group);
    }

    for (const auto& entry : entries_) {
      if (entry.record.parent == pid && entry.record.pid != pid && text.child_count < MonitorLimits::maximum_children) {
        text.children.atMut(text.child_count++) = {.pid = entry.record.pid, .name = entry.name.view()};
      }
    }

    // The nearest ancestors, collected upwards, then turned to read from the root down.
    auto ancestor = indexOf(record->parent);

    while (ancestor && text.lineage_count < MonitorLimits::maximum_lineage && entries_[*ancestor].record.pid != pid) {
      const auto& entry = entries_[*ancestor];

      text.lineage.atMut(text.lineage_count++) = {.pid = entry.record.pid, .name = entry.name.view()};
      if (entry.record.parent == entry.record.pid) {
        break;
      }

      ancestor = indexOf(entry.record.parent);
    }

    std::ranges::reverse(text.lineage.viewMut().first(text.lineage_count));
    return true;
  }

}

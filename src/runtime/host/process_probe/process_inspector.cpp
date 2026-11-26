module telar.runtime.host.process_probe;

import std;
import telar.sys.posix;

import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::runtime {
  namespace {
    constexpr std::size_t maximum_process_argument_bytes = std::size_t{16} * 1024;

    // The runtimes that run an agent's script, which its arguments then name.
    constexpr ds::Array<std::string_view, 3> generic_runtimes{"node", "bun", "deno"};
  }

  std::string_view processBasename(std::string_view path) noexcept {
    const auto slash = path.find_last_of("/\\");
    auto name = path;

    if (slash != std::string_view::npos) {
      name.remove_prefix(slash + 1);
    }

    return name;
  }

  ProcessArguments::ProcessArguments(std::string_view arguments) noexcept
      : arguments_(arguments) {}

  ProcessArguments ProcessArguments::fromMacos(std::span<const char> buffer) noexcept {
    if (buffer.size() <= sizeof(int)) {
      return ProcessArguments{{}};
    }

    int count = 0;

    std::ranges::copy(std::as_bytes(buffer.first(sizeof(count))), std::as_writable_bytes(std::span{&count, 1}).begin());
    const auto strings = buffer.subspan(sizeof(count));
    std::string_view remaining{strings.data(), strings.size()};
    const auto executable_end = remaining.find('\0');
    if (count <= 0 || executable_end == std::string_view::npos) {
      return ProcessArguments{{}};
    }

    const auto first_argument = remaining.find_first_not_of('\0', executable_end);
    if (first_argument == std::string_view::npos) {
      return ProcessArguments{{}};
    }

    remaining.remove_prefix(first_argument);
    std::size_t length = 0;

    for (int index = 0; index < count; ++index) {
      const auto end = remaining.find('\0', length);
      if (end == std::string_view::npos) {
        return ProcessArguments{{}};
      }

      length = end + 1;
    }

    remaining.remove_suffix(remaining.size() - length);
    return ProcessArguments{remaining};
  }

  AgentProvider ProcessArguments::provider(const AgentManifests& manifests, std::string_view command) const noexcept {
    auto detected = manifests.fromExecutable(processBasename(command));
    if (detected != AgentProvider::unknown) {
      return detected;
    }

    auto remaining = arguments_;
    const auto first = next(remaining);
    if (!first) {
      return AgentProvider::unknown;
    }

    detected = manifests.fromExecutable(processBasename(*first));
    if (detected != AgentProvider::unknown) {
      return detected;
    }

    if (!genericRuntime(command) && !genericRuntime(*first)) {
      return AgentProvider::unknown;
    }

    while (const auto argument = next(remaining)) {
      if (argument->starts_with('-')) {
        continue;
      }

      detected = manifests.fromExecutable(processBasename(*argument));
      return detected == AgentProvider::unknown ? manifests.fromPath(*argument) : detected;
    }

    return AgentProvider::unknown;
  }

  SessionHost ProcessArguments::sessionHost(AgentProvider provider) const noexcept {
    if (provider != AgentProvider::codex || arguments_.empty()) {
      return SessionHost::unknown;
    }

    auto host = SessionHost::shared_server;
    auto remaining = arguments_;

    while (const auto argument = next(remaining)) {
      if (isCodexBatchArgument(*argument)) {
        return SessionHost::unknown;
      }

      if (*argument == codex_pane_argument) {
        host = SessionHost::pane;
      }
    }

    return host;
  }

  std::string_view ProcessArguments::joined(std::span<char> output) const noexcept {
    auto remaining = arguments_;
    std::size_t length = 0;

    while (const auto argument = next(remaining)) {
      if (length != 0 && length < output.size()) {
        output[length++] = ' ';
      }

      const auto count = std::min(argument->size(), output.size() - length);

      std::ranges::copy(std::span{*argument}.first(count), output.subspan(length).begin());
      length += count;
      if (length == output.size()) {
        break;
      }
    }

    return {output.data(), length};
  }

  std::string_view ProcessArguments::quoted(std::span<char> output) const noexcept {
    // A quote ends the quoted text, writes itself escaped and opens it again: '\''.
    constexpr std::string_view escaped_quote = "'\\''";
    const auto plain = [](char byte) {
      return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || std::string_view{"@%+=:,./_-"}.contains(byte);
    };

    auto remaining = arguments_;
    std::size_t length = 0;

    while (const auto argument = next(remaining)) {
      const auto bare = std::ranges::all_of(*argument, plain);
      const auto quotes = static_cast<std::size_t>(std::ranges::count(*argument, '\''));
      const auto separator = length == 0 ? std::size_t{0} : std::size_t{1};
      const auto needed = bare ? argument->size() : argument->size() + 2 + (quotes * (escaped_quote.size() - 1));
      if (length + separator + needed > output.size()) {
        break;
      }

      auto written = output.subspan(length);

      if (separator != 0) {
        written[0] = ' ';
        written = written.subspan(1);
      }

      if (bare) {
        std::ranges::copy(*argument, written.begin());
      } else {
        auto cursor = written.begin();

        *cursor++ = '\'';
        for (const auto byte : *argument) {
          if (byte == '\'') {
            cursor = std::ranges::copy(escaped_quote, cursor).out;
          } else {
            *cursor++ = byte;
          }
        }

        *cursor = '\'';
      }

      length += separator + needed;
    }

    return {output.data(), length};
  }

  ds::Option<std::string_view> ProcessArguments::next(std::string_view& remaining) noexcept {
    const auto first = remaining.find_first_not_of('\0');
    if (first == std::string_view::npos) {
      return ds::none;
    }

    remaining.remove_prefix(first);
    const auto end = remaining.find('\0');
    auto argument = remaining;

    if (end == std::string_view::npos) {
      remaining = {};
    } else {
      argument.remove_suffix(argument.size() - end);
      remaining.remove_prefix(end + 1);
    }

    return argument;
  }

  bool ProcessArguments::genericRuntime(std::string_view command) noexcept {
    constexpr std::string_view windows_suffix = ".exe";
    auto name = processBasename(command);
    auto suffix = name;

    if (name.size() >= windows_suffix.size()) {
      suffix.remove_prefix(name.size() - windows_suffix.size());
      if (containsInsensitive(suffix, windows_suffix)) {
        name.remove_suffix(windows_suffix.size());
      }
    }

    return std::ranges::any_of(generic_runtimes, [&](std::string_view candidate) {
      return name.size() == candidate.size() && containsInsensitive(name, candidate);
    });
  }

  std::span<const pid_t> ProcessLineage::ancestors() const noexcept {
    return std::span{processes}.first(count);
  }

  bool ProcessIdentity::sameInstance(const ProcessIdentity& other) const noexcept {
    return pid == other.pid && started_seconds == other.started_seconds && started_microseconds == other.started_microseconds;
  }

  void ListeningPorts::add(std::uint16_t port) noexcept {
    const auto stored = values.view().first(count);
    const auto index = static_cast<std::size_t>(std::ranges::lower_bound(stored, port) - stored.begin());
    const auto full = count == values.size();
    if (port == 0 || (index != count && stored[index] == port) || (full && index == count)) {
      return;
    }

    // A full list drops its highest port to make room.
    const auto moved = values.viewMut().first(full ? count : count + 1).subspan(index);

    std::ranges::shift_right(moved, 1);
    values.atMut(index) = port;
    if (!full) {
      ++count;
    }
  }

  std::span<const std::uint16_t> ListeningPorts::view() const noexcept {
    return std::span{values}.first(count);
  }

  bool ListeningPorts::operator==(const ListeningPorts& other) const noexcept {
    return std::ranges::equal(view(), other.view());
  }

  ProcessInspector::ProcessInspector(const AgentManifests& manifests, uid_t uid) noexcept
      : manifests_(manifests),
        uid_(uid) {}

  ds::Option<ProcessIdentity> ProcessInspector::identity(pid_t process) const noexcept {
    const auto observed = snapshot(process);

    return observed ? ds::Option{observed->identity} : ds::none;
  }

  bool ProcessInspector::descendsFrom(const ProcessIdentity& process, pid_t root) const noexcept {
    return lineage(process, root).descends;
  }

  ProcessLineage ProcessInspector::lineage(const ProcessIdentity& process, pid_t root) const noexcept {
    ProcessLineage result;
    auto current = identity(process.pid);
    if (current != process) {
      return result;
    }

    result.descends = process.pid == root;
    while (current && result.count < result.processes.size() && current->parent > 0) {
      result.processes.atMut(result.count++) = current->parent;
      result.descends |= current->parent == root;
      if (current->parent == 1 || current->parent == current->pid) {
        break;
      }

      current = identity(current->parent);
    }

    return result;
  }

  AgentProvider ProcessInspector::provider(pid_t process) const noexcept {
    const auto path = executable(process);
    if (path.view().empty()) {
      return AgentProvider::unknown;
    }

    const auto identified = manifests_.fromExecutable(processBasename(path.view()));
    if (identified != AgentProvider::unknown) {
      return identified;
    }

    ds::Array<char, maximum_process_argument_bytes> arguments; // NOLINT(cppcoreguidelines-pro-type-member-init): sysctl writes the arguments it reports, and only those are read, so zeroing 16 KiB per process is work no read needs

    return readArguments(process, arguments.viewMut()).provider(manifests_, path.view());
  }

  CommandLine ProcessInspector::commandLine(pid_t process, std::span<char> output) const noexcept {
    ds::Array<char, maximum_process_argument_bytes> storage; // NOLINT(cppcoreguidelines-pro-type-member-init): sysctl writes the arguments it reports, and only those are read, so zeroing 16 KiB per process is work no read needs
    const auto path = executable(process);
    const auto arguments = readArguments(process, storage.viewMut());
    const auto provider = path.view().empty() ? AgentProvider::unknown : arguments.provider(manifests_, path.view());

    return {.text = arguments.joined(output), .path = path, .provider = provider};
  }

  std::string_view ProcessInspector::quotedArguments(pid_t process, std::span<char> output) const noexcept {
    ds::Array<char, maximum_process_argument_bytes> storage; // NOLINT(cppcoreguidelines-pro-type-member-init): sysctl writes the arguments it reports, and only those are read, so zeroing 16 KiB per process is work no read needs

    return readArguments(process, storage.viewMut()).quoted(output);
  }

  // A manifest's display name always fits a process name.
  static_assert(AgentManifest::name_bytes <= process_name_bytes);

  IdentifiedProcess ProcessInspector::identifyProcess(pid_t process) const noexcept { // NOLINT(bugprone-exception-escape): assign throws only past its capacity, which a display name never reaches
    IdentifiedProcess identified;

    identified.identity = identity(process);
    if (!identified.identity) {
      return identified;
    }

    identified.name = name(process);
    ds::Array<char, maximum_process_argument_bytes> storage; // NOLINT(cppcoreguidelines-pro-type-member-init): sysctl writes the arguments it reports, and only those are read, so zeroing 16 KiB per process is work no read needs
    const auto arguments = readArguments(process, storage.viewMut());

    identified.provider = arguments.provider(manifests_, identified.name.view());
    identified.session_host = arguments.sessionHost(identified.provider);
    if (const auto* manifest = manifests_.find(identified.provider)) {
      identified.name.assign(manifest->displayName());
    }

    // A process that exited or was replaced meanwhile is not the one identified.
    if (identity(process) != identified.identity) {
      identified = IdentifiedProcess{};
    }

    return identified;
  }

  IdentifiedProcess ProcessInspector::identifyGroup(pid_t group, AgentProvider preferred) const noexcept {
    constexpr std::size_t maximum_group_processes = 64;
    // The leader, unless a member runs an agent, or the leader has no name and a member does.
    auto identified = identifyProcess(group);
    if (group <= 0 || identified.provider != AgentProvider::unknown) {
      return identified;
    }

    ds::Array<pid_t, maximum_group_processes> members{};
    const auto count = groupMembers(group, members.viewMut());
    ds::Option<IdentifiedProcess> selected;

    for (const auto member : std::span{members}.first(count)) {
      if (member <= 0 || member == group) {
        continue;
      }

      const auto candidate = identifyProcess(member);
      if (!candidate.identity || candidate.identity->process_group != group) {
        continue;
      }

      if (candidate.provider == AgentProvider::unknown) {
        if (identified.name.view().empty()) {
          identified = candidate;
        }

        continue;
      }

      if (preferred == AgentProvider::unknown || candidate.provider == preferred) {
        selected = candidate;
        break;
      }

      if (!selected) {
        selected = candidate;
      }
    }

    if (selected) {
      identified = *selected;
    }

    return identified;
  }

  bool ProcessCache::needsIdentification(pid_t foreground, bool recheck) const noexcept {
    return foreground > 0 && (recheck || foreground != group || (identified.provider == AgentProvider::unknown && attempts < acquisition_attempts));
  }

  AgentProvider ProcessCache::preferred(pid_t foreground) const noexcept {
    return foreground == group ? identified.provider : AgentProvider::unknown;
  }

  void ProcessCache::update(pid_t foreground, const IdentifiedProcess& process, bool installed) noexcept { // NOLINT(bugprone-exception-escape): assign throws only past its capacity, which "process" never reaches
    if (process.provider != AgentProvider::unknown) {
      attempts = 0;
    } else if (foreground == group) {
      attempts = std::min(attempts + 1, acquisition_attempts);
    } else {
      attempts = 1;
    }

    group = foreground;
    identified = process;
    if (identified.name.view().empty()) {
      identified.name.assign("process");
    }

    hooks_installed = installed;
  }

}

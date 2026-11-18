module telar.config.runtime;

import std;
import telar.lua;
import telar.tbc;
import telar.sys.socket;
import telar.base.ds;

namespace telar::runtime {

  bool AgentEvidence::expired(std::int64_t now) const noexcept {
    return expires_at <= now;
  }

  AgentEvidence AgentEvidence::process(AgentProvider provider, ObservationTime now) noexcept {
    return {provider, AgentStatus::ready, AgentSource::foreground_process, 100, now, std::numeric_limits<std::int64_t>::max()};
  }

  AgentEvidence AgentEvidence::screen(AgentProvider provider, AgentSignal signal, ObservationTime now) noexcept {
    return {provider, signal.status, AgentSource::screen, signal.confidence, now, now.milliseconds + (signal.status == AgentStatus::working ? screen_working_expiry : settled_expiry).count()};
  }

  AgentEvidence AgentEvidence::report(AgentProvider provider, AgentReportState state, ObservationTime now) noexcept {
    const bool working = state == AgentReportState::working || state == AgentReportState::waiting || state == AgentReportState::settling;
    const auto expiry = working ? (state == AgentReportState::settling ? screen_working_expiry : report_working_expiry) : settled_expiry;
    const auto status = working ? AgentStatus::working : state == AgentReportState::blocked ? AgentStatus::blocked
                                                                                            : AgentStatus::ready;

    return {provider, status, AgentSource::lifecycle_report, 100, now, now.milliseconds + expiry.count()};
  }

  bool completionRequiresSignal(AgentProvider provider) noexcept {
    return provider == AgentProvider::codex || provider == AgentProvider::pi || provider == AgentProvider::cursor || provider == AgentProvider::opencode;
  }

  bool containsInsensitive(std::string_view text, std::string_view phrase) noexcept {
    if (phrase.empty() || phrase.size() > text.size()) {
      return false;
    }

    for (std::size_t offset = 0; offset <= text.size() - phrase.size(); ++offset) {
      if (std::equal(phrase.begin(), phrase.end(), text.begin() + offset, [](char left, char right) {
            return asciiLower(left) == asciiLower(right);
          })) {
        return true;
      }
    }

    return false;
  }

  template <std::size_t Capacity, std::size_t TextCapacity>
  void ManifestTextList<Capacity, TextCapacity>::append(std::string_view text) {
    if (text.empty() || text.size() > TextCapacity || count_ == Capacity) {
      throw EncodingError{"Agent manifest list exceeds its bounds"};
    }

    entries_.atMut(count_++).assign(text);
  }

  template <std::size_t Capacity, std::size_t TextCapacity>
  bool ManifestTextList<Capacity, TextCapacity>::matches(std::string_view text) const noexcept {
    return std::ranges::any_of(entries(), [&](const auto& phrase) {
      return containsInsensitive(text, phrase.view());
    });
  }

  template <std::size_t Capacity, std::size_t TextCapacity>
  std::span<const FixedText<TextCapacity>> ManifestTextList<Capacity, TextCapacity>::entries() const noexcept {
    return std::span{entries_}.first(count_);
  }

  template class ManifestTextList<8, 128>;
  template class ManifestTextList<16, 64>;

  void AgentManifest::addCommandTool(std::string_view name, std::string_view field) {
    if (name.empty() || name.size() > 64 || field.empty() || field.size() > 32 || tool_count == command_tools.size()) {
      throw EncodingError{"Invalid agent command tool"};
    }

    command_tools.atMut(tool_count).tool.assign(name);
    command_tools.atMut(tool_count).field.assign(field);
    ++tool_count;
  }

  std::string_view AgentManifest::commandField(std::string_view tool) const noexcept {
    for (const auto& mapping : std::span{command_tools}.first(tool_count)) {
      if (mapping.tool.view() == tool) {
        return mapping.field.view();
      }
    }

    return {};
  }

  std::string_view AgentManifest::displayName() const noexcept {
    return display_name.view().empty() ? name.view() : display_name.view();
  }

  tbc::view<std::string_view, tbc::lt::a> AgentManifest::placeholderTitle(tbc::view<FixedText<96>&, tbc::lt::a> storage) const {
    if (!placeholder.view().empty()) {
      return placeholder.view();
    }

    ds::Array<char, 96> bytes{};
    const auto display = displayName();

    std::memcpy(bytes.dataMut(), "New ", 4);
    std::memcpy(bytes.dataMut() + 4, display.data(), display.size());
    std::memcpy(bytes.dataMut() + 4 + display.size(), " session", 8);
    storage.assign({bytes.data(), display.size() + 12});
    return storage.view();
  }

  AgentManifest& AgentManifests::add(std::string_view name) {
    auto* manifest = tryAdd(name);
    if (manifest == nullptr) {
      throw EncodingError{"Too many agent manifests"};
    }

    return *manifest;
  }

  AgentManifest* AgentManifests::tryAdd(std::string_view name) {
    if (name.empty() || name.size() > 32 || !std::ranges::all_of(name, [](char byte) {
          return (byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') || byte == '-' || byte == '_' || byte == '.';
        })) {
      throw EncodingError{"Invalid agent manifest name"};
    }

    const auto builtin = providerNamed(name);

    for (auto& entry : entries_.viewMut().first(count_)) {
      if (entry.name.view() == name) {
        if (builtin == AgentProvider::unknown) {
          throw EncodingError{"Duplicate agent manifest"};
        }

        return &entry;
      }
    }

    if (count_ >= entries_.size() || (builtin == AgentProvider::unknown && custom_count_ >= maximum_custom_agents)) {
      return nullptr;
    }

    auto& entry = entries_.atMut(count_++);

    entry.provider = builtin == AgentProvider::unknown ? static_cast<AgentProvider>(first_custom_provider + custom_count_++) : builtin;
    entry.name.assign(name);
    return &entry;
  }

  const AgentManifest* AgentManifests::find(AgentProvider provider) const noexcept {
    for (const auto& entry : entries()) {
      if (entry.provider == provider) {
        return &entry;
      }
    }

    return nullptr;
  }

  AgentProvider AgentManifests::named(std::string_view name) const noexcept {
    for (const auto& entry : entries()) {
      if (entry.name.view() == name) {
        return entry.provider;
      }
    }

    return AgentProvider::unknown;
  }

  AgentProvider AgentManifests::fromExecutable(std::string_view name) const noexcept {
    const auto stem = withoutExecutableSuffix(name);

    for (const auto& entry : entries()) {
      for (const auto& candidate : entry.process_names.entries()) {
        if (asciiEqualIgnoreCase(stem, candidate.view())) {
          return entry.provider;
        }
      }
    }

    return AgentProvider::unknown;
  }

  AgentProvider AgentManifests::fromPath(std::string_view path) const noexcept {
    for (const auto& entry : entries()) {
      if (entry.process_paths.matches(path)) {
        return entry.provider;
      }
    }

    return AgentProvider::unknown;
  }

  ds::Option<AgentSignal> AgentManifests::detect(std::string_view text) const noexcept {
    for (const auto& entry : entries()) {
      if (entry.blocked.matches(text)) {
        return AgentSignal{inferProvider(text), AgentStatus::blocked, 88};
      }
    }

    for (const auto& entry : entries()) {
      if (entry.working.matches(text)) {
        return AgentSignal{inferProvider(text), AgentStatus::working, 78};
      }
    }

    for (const auto& entry : entries()) {
      if (entry.ready_prompt.matches(text)) {
        return AgentSignal{entry.provider, AgentStatus::ready, 94, true, true};
      }
    }

    for (const auto& entry : entries()) {
      if (entry.identity.matches(text)) {
        return AgentSignal{entry.provider, AgentStatus::ready, 90, true, false};
      }
    }

    return ds::none;
  }

  std::span<const AgentManifest> AgentManifests::entries() const noexcept {
    return std::span{entries_}.first(count_);
  }

  AgentProvider AgentManifests::inferProvider(std::string_view text) const noexcept {
    for (const auto& entry : entries()) {
      if (entry.brand.matches(text)) {
        return entry.provider;
      }
    }

    return AgentProvider::unknown;
  }

  AgentManifests makeBuiltinManifests() {
    AgentManifests table;

    for (const auto provider : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
      const auto description = describeProvider(provider);
      auto& manifest = table.add(description.name);

      manifest.display_name.assign(description.display_name);
      manifest.attachments = description.attachments;
      manifest.interrupt = AgentInterruptKey::escape;
      for (const auto process : description.process_names) {
        if (!process.empty()) {
          manifest.process_names.append(process);
        }
      }
    }

    auto& claude = table.add("claude");

    claude.process_paths.append("/@anthropic-ai/claude-code/");
    claude.process_paths.append("\\@anthropic-ai\\claude-code\\");
    claude.brand.append("claude");
    claude.identity.append("claude code");
    claude.addCommandTool("Bash", "command");
    claude.interrupt = AgentInterruptKey::control_c;
    for (const auto phrase : {"press enter to confirm", "enter to submit answer", "enter to select", "allow command?", "[y/n]", "do you want to proceed?", "waiting for permission", "yes, and don't ask again"}) {
      claude.blocked.append(phrase);
    }

    for (const auto phrase : {"esc to interrupt", "working (", "waiting for background agents", "tasks still running", "background shells"}) {
      claude.working.append(phrase);
    }

    auto& codex = table.add("codex");

    codex.process_paths.append("/@openai/codex/");
    codex.process_paths.append("\\@openai\\codex\\");
    codex.brand.append("codex");
    codex.ready_prompt.append("ask codex to do anything");
    codex.addCommandTool("Bash", "command");
    codex.addCommandTool("exec_command", "cmd");
    codex.addCommandTool("shell", "command");

    auto& pi = table.add("pi");

    pi.process_paths.append("/@earendil-works/pi-coding-agent/");
    pi.process_paths.append("\\@earendil-works\\pi-coding-agent\\");
    pi.process_paths.append("/@mariozechner/pi-coding-agent/");
    pi.process_paths.append("\\@mariozechner\\pi-coding-agent\\");
    pi.addCommandTool("bash", "command");

    auto& cursor = table.add("cursor");

    cursor.process_paths.append("/cursor-agent/versions/");
    cursor.addCommandTool("Shell", "command");
    for (const auto phrase : {"not in allowlist:", "skip & tell the agent what to do instead", "yes, build locally", "do you trust the contents of this directory?"}) {
      cursor.blocked.append(phrase);
    }

    auto& opencode = table.add("opencode");

    opencode.interrupt = AgentInterruptKey::escape_twice;
    opencode.addCommandTool("bash", "command");
    return table;
  }

  void HistoryPatternList::append(std::string_view pattern) {
    if (pattern.empty() || pattern.find('\0') != std::string_view::npos) {
      throw std::invalid_argument{"History filter patterns must not be empty or contain NUL"};
    }

    if (count_ == patterns_.size()) {
      throw std::length_error{"History filter exceeds 64 patterns"};
    }

    patterns_.atMut(count_).assign(pattern);
    ++count_;
  }

  bool HistoryPatternList::matches(std::string_view text) const noexcept {
    for (const auto& pattern : std::span{patterns_}.first(count_)) {
      if (text.contains(pattern.view())) {
        return true;
      }
    }

    return false;
  }

  bool HistoryFilters::allowsPane(std::string_view command, std::string_view directory) const noexcept {
    return !command.empty() && command.front() != ' ' && allowsAgent(command, directory);
  }

  bool HistoryFilters::allowsAgent(std::string_view command, std::string_view directory, bool redact) const noexcept {
    return !command.empty() && !(redact && secrets && looksLikeSecret(command)) && !commands.matches(command) && !directories.matches(directory);
  }

  bool HistoryFilters::looksLikeSecret(std::string_view command) noexcept {
    constexpr ds::Array tokens{
        TokenRule{"AKIA", 16},
        TokenRule{"ghp_", 20},
        TokenRule{"gho_", 20},
        TokenRule{"github_pat_", 20},
        TokenRule{"npm_", 30},
        TokenRule{"sk_live_", 12},
        TokenRule{"rk_live_", 12},
        TokenRule{"xoxb-", 10},
        TokenRule{"xoxp-", 10},
    };

    for (const auto& rule : tokens) {
      if (matchesToken(command, rule)) {
        return true;
      }
    }

    if (command.contains("hooks.slack.com/services/") || command.contains("-----BEGIN")) {
      return true;
    }

    constexpr ds::Array<std::string_view, 5> assignments{"password=", "passwd=", "token=", "secret=", "api_key="};

    for (const auto marker : assignments) {
      if (matchesAssignment(command, marker)) {
        return true;
      }
    }

    return false;
  }

  bool HistoryFilters::tokenByte(unsigned char byte) noexcept {
    return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-';
  }

  bool HistoryFilters::matchesToken(std::string_view command, const TokenRule& rule) noexcept {
    for (std::size_t offset = 0; offset < command.size();) {
      const auto found = command.find(rule.marker, offset);
      if (found == std::string_view::npos) {
        return false;
      }

      const auto suffix = command.substr(found + rule.marker.size());
      std::size_t length = 0;

      while (length < suffix.size() && tokenByte(suffix[length])) {
        ++length;
      }

      if (length >= rule.minimum_length) {
        return true;
      }

      offset = found + 1;
    }

    return false;
  }

  bool HistoryFilters::matchesAssignment(std::string_view command, std::string_view marker) noexcept {
    for (std::size_t offset = 0; offset + marker.size() < command.size(); ++offset) {
      bool matches = true;

      for (std::size_t index = 0; index < marker.size(); ++index) {
        const unsigned char byte = command[offset + index];
        const auto lower = byte >= 'A' && byte <= 'Z' ? byte + ('a' - 'A') : byte;
        if (lower != marker[index]) {
          matches = false;
          break;
        }
      }

      const auto value = command[offset + marker.size()];
      if (matches && value != ' ' && value != '"' && value != '\'') {
        return true;
      }
    }

    return false;
  }

  bool ProxyCaptureLimits::valid() const noexcept {
    return part_bytes != 0 && exchange_bytes >= 2 && total_bytes != 0 && part_bytes <= exchange_bytes && exchange_bytes <= total_bytes && exchange_bytes <= maximum_exchange_bytes && total_bytes <= maximum_total_bytes && join_timeout.count() > 0 && join_timeout <= maximum_join_timeout;
  }

  template <Allocator Memory>
  ProxyHostPolicy<Memory>::ProxyHostPolicy(Memory& memory)
      : patterns_(memory) {}

  template <Allocator Memory>
  ProxyHostPolicy<Memory> ProxyHostPolicy<Memory>::clone() const {
    ProxyHostPolicy copy{patterns_.memory()};

    copy.patterns_ = patterns_.clone();
    return copy;
  }

  template <Allocator Memory>
  bool ProxyHostPolicy<Memory>::validPattern(std::string_view pattern) noexcept {
    return ProxyHostname::validPattern(pattern);
  }

  template <Allocator Memory>
  bool ProxyHostPolicy<Memory>::append(std::string_view pattern) {
    if (patterns_.size() == maximum_hosts || !validPattern(pattern)) {
      return false;
    }

    ds::Array<char, INET6_ADDRSTRLEN> numeric{};

    if (const auto address = ProxyHostname::ipv6(pattern)) {
      ::inet_ntop(AF_INET6, &*address, numeric.dataMut(), numeric.size());
      pattern = numeric.data();
    }

    patterns_.emplace(patterns_.memory(), pattern);
    auto& added = patterns_.backMut();

    std::ranges::transform(added.view(), added.dataMut(), asciiLower);
    return true;
  }

  template <Allocator Memory>
  void ProxyHostPolicy<Memory>::finish() {
    std::ranges::sort(patterns_.viewMut());
    const auto duplicates = std::ranges::unique(patterns_.viewMut());

    patterns_.truncate(patterns_.size() - duplicates.size());
  }

  template <Allocator Memory>
  void ProxyHostPolicy<Memory>::clear() noexcept {
    patterns_.clear();
  }

  template <Allocator Memory>
  bool ProxyHostPolicy<Memory>::contains(std::string_view hostname) const noexcept {
    if (hostname.empty() || patterns_.empty()) {
      return false;
    }

    if (patterns_.front() == "*") {
      return true;
    }

    if (hostname.size() > maximum_hostname_bytes) {
      return false;
    }

    if (const auto address = ProxyHostname::ipv6(hostname)) {
      ds::Array<char, INET6_ADDRSTRLEN> numeric{};

      ::inet_ntop(AF_INET6, &*address, numeric.dataMut(), numeric.size());
      return find(numeric.data());
    }

    ds::Array<char, maximum_hostname_bytes + wildcard_prefix.size()> canonical;

    std::ranges::transform(hostname, canonical.viewMut().begin() + wildcard_prefix.size(), asciiLower);
    const std::string_view exact{canonical.data() + wildcard_prefix.size(), hostname.size()};
    if (find(exact)) {
      return true;
    }

    for (auto dot = hostname.find('.'); dot != std::string_view::npos; dot = hostname.find('.', dot + 1)) {
      const auto start = dot + 1;

      std::ranges::copy(wildcard_prefix, canonical.dataMut() + start);
      if (find({canonical.data() + start, hostname.size() - start + wildcard_prefix.size()})) {
        return true;
      }
    }

    return false;
  }

  template <Allocator Memory>
  std::span<const ds::String<Memory>> ProxyHostPolicy<Memory>::patterns() const noexcept {
    return patterns_;
  }

  template <Allocator Memory>
  bool ProxyHostPolicy<Memory>::find(std::string_view pattern) const noexcept {
    const auto found = std::lower_bound(patterns_.begin(), patterns_.end(), pattern, [](const auto& entry, std::string_view value) {
      return std::string_view{entry} < value;
    });

    return found != patterns_.end() && *found == pattern;
  }

  template class ProxyHostPolicy<Memory>;
  template class ProxyHostPolicy<ConcurrentMemory>;
  template class ProxyHostPolicy<SystemAllocator>;
  template class ProxyHostPolicy<BudgetAllocator<SystemAllocator>>;
  template class ProxyHostPolicy<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

  template <Allocator Memory>
  ProxyOptions<Memory>::ProxyOptions(Memory& memory)
      : authority_directory(memory),
        intercept_hosts(memory) {}

  template <Allocator Memory>
  ProxyOptions<Memory> ProxyOptions<Memory>::clone() const {
    ProxyOptions copy{authority_directory.memory()};

    copy.authority_directory = authority_directory.clone();
    copy.intercept_hosts = intercept_hosts.clone();
    copy.capture = capture;
    copy.enabled = enabled;
    copy.anonymous_tunnels = anonymous_tunnels;
    copy.pane_https_proxy = pane_https_proxy;
    copy.network_capture = network_capture;
    copy.network_control = network_control;
    copy.transparent_redirect = transparent_redirect;
    copy.transparent_tls = transparent_tls;
    copy.stream_interception = stream_interception;
    return copy;
  }

  template struct ProxyOptions<Memory>;
  template struct ProxyOptions<ConcurrentMemory>;
  template struct ProxyOptions<SystemAllocator>;
  template struct ProxyOptions<BudgetAllocator<SystemAllocator>>;
  template struct ProxyOptions<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

}

namespace telar::runtime::config {

  void readControlPolicy(const lua::Value& table, control::Policy& policy) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"clipboard_read", "clipboard_write", "title_report", "checksum_report", "color_format", "answerback"});
    const auto access = [](const lua::Value& value, control::Access fallback) {
      if (!value.present()) {
        return fallback;
      }

      const auto text = value.string();
      if (text == "deny") {
        return control::Access::deny;
      }

      if (text == "ask") {
        return control::Access::ask;
      }

      if (text == "allow") {
        return control::Access::allow;
      }

      value.fail("must be deny, ask or allow");
    };

    policy.clipboard_read = access(table.field("clipboard_read"), policy.clipboard_read);
    policy.clipboard_write = access(table.field("clipboard_write"), policy.clipboard_write);
    policy.title_report = table.field("title_report").boolean(policy.title_report);
    policy.checksum_report = table.field("checksum_report").boolean(policy.checksum_report);

    const auto format = table.field("color_format");
    if (format.present()) {
      const auto text = format.string();
      if (text == "none") {
        policy.color_format = control::ColorFormat::none;
      } else if (text == "8-bit") {
        policy.color_format = control::ColorFormat::eight_bit;
      } else if (text == "16-bit") {
        policy.color_format = control::ColorFormat::sixteen_bit;
      } else {
        format.fail("must be none, 8-bit or 16-bit");
      }
    }

    const auto answerback = table.field("answerback");
    if (answerback.present()) {
      const auto text = answerback.string();
      if (text.size() > policy.answerback.size()) {
        answerback.fail("exceeds 1024 bytes");
      }

      std::copy(text.begin(), text.end(), policy.answerback.dataMut());
      policy.answerback_length = static_cast<std::uint16_t>(text.size());
    }
  }

  template <Allocator Memory>
  void ProxyReader<Memory>::read(const lua::Value& table, ProxyOptions<Memory>& values) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"enabled", "anonymous_tunnels", "pane_https_proxy", "ca_dir", "intercept_hosts", "capture", "network_capture", "network_control", "transparent_redirect", "transparent_tls", "stream_interception"});
    values.enabled = table.field("enabled").boolean(values.enabled);
    values.anonymous_tunnels = table.field("anonymous_tunnels").boolean(values.anonymous_tunnels);
    values.pane_https_proxy = table.field("pane_https_proxy").boolean(values.pane_https_proxy);
    values.network_capture = table.field("network_capture").boolean(values.network_capture);
    values.network_control = table.field("network_control").boolean(values.network_control);
    if (values.network_control && !values.network_capture) {
      table.fail("network_control requires network_capture");
    }

    values.transparent_redirect = table.field("transparent_redirect").boolean(values.transparent_redirect);
    values.transparent_tls = table.field("transparent_tls").boolean(values.transparent_tls);
    values.stream_interception = table.field("stream_interception").boolean(values.stream_interception);
    if (values.transparent_tls && !values.transparent_redirect) {
      table.fail("transparent_tls requires transparent_redirect");
    }

    if (values.stream_interception && (!values.enabled || !values.network_capture)) {
      table.fail("stream_interception requires enabled and network_capture");
    }

    if (values.transparent_redirect && !values.enabled) {
      table.fail("transparent_redirect requires the proxy to be enabled");
    }

    capture(table.field("capture"), values.capture);
    const auto directory = table.field("ca_dir");
    if (directory.present()) {
      const auto text = directory.string();
      if (text.empty() || text.size() > maximum_path_bytes || text.contains('\0')) {
        directory.fail("is invalid");
      }

      values.authority_directory.assign(text);
    }

    const auto hosts = table.field("intercept_hosts");
    if (!hosts.present()) {
      return;
    }

    const auto count = hosts.arraySize();
    if (count > ProxyHostPolicy<Memory>::maximum_hosts) {
      hosts.fail("exceeds 256 entries");
    }

    values.intercept_hosts.clear();
    for (std::size_t index = 1; index <= count; ++index) {
      const auto host = hosts.element(static_cast<lua_Integer>(index));
      if (!values.intercept_hosts.append(host.string())) {
        host.fail("is not a valid hostname");
      }
    }

    values.intercept_hosts.finish();
  }

  template <Allocator Memory>
  std::size_t ProxyReader<Memory>::positive(const lua::Value& field, std::size_t fallback) {
    return field.boundedInteger(fallback, 1, std::numeric_limits<std::size_t>::max());
  }

  template <Allocator Memory>
  void ProxyReader<Memory>::capture(const lua::Value& table, ProxyCaptureLimits& limits) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"enabled", "max_part_bytes", "max_exchange_bytes", "max_total_bytes", "join_timeout_ms"});
    limits.enabled = table.field("enabled").boolean(limits.enabled);
    limits.part_bytes = positive(table.field("max_part_bytes"), limits.part_bytes);
    limits.exchange_bytes = positive(table.field("max_exchange_bytes"), limits.exchange_bytes);
    limits.total_bytes = positive(table.field("max_total_bytes"), limits.total_bytes);
    const auto timeout = positive(table.field("join_timeout_ms"), static_cast<std::size_t>(limits.join_timeout.count()));
    if (timeout > static_cast<std::size_t>(std::chrono::duration_cast<std::chrono::milliseconds>(ProxyCaptureLimits::maximum_join_timeout).count())) {
      table.field("join_timeout_ms").fail("exceeds its 3600000 ms ceiling");
    }

    limits.join_timeout = std::chrono::milliseconds{timeout};

    if (limits.exchange_bytes < 2 || limits.part_bytes > limits.exchange_bytes || limits.exchange_bytes > limits.total_bytes) {
      table.fail("byte limits must satisfy part <= exchange <= total");
    }

    if (limits.exchange_bytes > ProxyCaptureLimits::maximum_exchange_bytes) {
      table.field("max_exchange_bytes").fail("exceeds its 67108864-byte ceiling");
    }

    if (limits.total_bytes > ProxyCaptureLimits::maximum_total_bytes) {
      table.field("max_total_bytes").fail("exceeds its 1073741824-byte ceiling");
    }
  }

  template class ProxyReader<Memory>;
  template class ProxyReader<ConcurrentMemory>;
  template class ProxyReader<SystemAllocator>;
  template class ProxyReader<BudgetAllocator<SystemAllocator>>;
  template class ProxyReader<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

  template <Allocator Memory>
  std::span<const std::string_view> CommandValues<Memory>::Views::span() const noexcept {
    return std::span{words}.first(count);
  }

  template <Allocator Memory>
  CommandValues<Memory>::CommandValues(Memory& memory)
      : arguments(memory) {}

  template <Allocator Memory>
  CommandValues<Memory> CommandValues<Memory>::clone() const {
    CommandValues copy{arguments.memory()};

    copy.arguments = arguments.clone();
    copy.timeout = timeout;
    copy.idle_timeout = idle_timeout;
    return copy;
  }

  template <Allocator Memory>
  typename CommandValues<Memory>::Views CommandValues<Memory>::views() const noexcept {
    Views views;

    for (const auto& argument : arguments) {
      views.words.atMut(views.count++) = argument;
    }

    return views;
  }

  template <Allocator Memory>
  RuntimeValues<Memory>::RuntimeValues(Memory& memory)
      : history_path(memory),
        session_path(memory),
        engine(memory),
        descriptions(memory),
        proxy(memory) {}

  template <Allocator Memory>
  RuntimeValues<Memory> RuntimeValues<Memory>::clone() const {
    RuntimeValues copy{history_path.memory()};

    copy.history_path = history_path.clone();
    copy.session_path = session_path.clone();
    copy.history_filters = history_filters;
    copy.engine = engine.clone();
    copy.descriptions = descriptions.clone();
    copy.proxy = proxy.clone();
    copy.plugins = plugins;
    copy.configuration_directory = configuration_directory;
    copy.manifests = manifests;
    copy.limits = limits;
    copy.graphics = graphics;
    copy.control_policy = control_policy;
    copy.capture_output = capture_output;
    copy.persist_session = persist_session;
    copy.resume_agents = resume_agents;
    copy.shell_integration = shell_integration;
    copy.ssh_integration = ssh_integration;
    return copy;
  }

  template struct CommandValues<Memory>;
  template struct CommandValues<ConcurrentMemory>;
  template struct RuntimeValues<Memory>;
  template struct RuntimeValues<ConcurrentMemory>;

}

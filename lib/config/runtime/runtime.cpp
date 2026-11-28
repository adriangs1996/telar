module telar.config.runtime;

import std;
import telar.lua;
import telar.tbc;
import telar.sys.socket;
import telar.base.ds;
import telar.base.history.secrets;
import telar.base.text.pattern;
import telar.base.text.utf8;

namespace telar::runtime {

  namespace {

    // How sure each kind of evidence is that it names the agent's state, in percent.
    constexpr Byte certain_confidence = 100;
    constexpr Byte blocked_confidence = 88;
    constexpr Byte working_confidence = 78;
    constexpr Byte ready_prompt_confidence = 94;
    constexpr Byte identity_confidence = 90;

    std::chrono::milliseconds reportExpiry(AgentReportState state) noexcept {
      if (state == AgentReportState::settling) {
        return AgentEvidence::screen_working_expiry;
      }

      if (state == AgentReportState::working || state == AgentReportState::waiting) {
        return AgentEvidence::report_working_expiry;
      }

      return AgentEvidence::settled_expiry;
    }

    AgentStatus reportStatus(AgentReportState state) noexcept {
      if (state == AgentReportState::working || state == AgentReportState::waiting || state == AgentReportState::settling) {
        return AgentStatus::working;
      }

      if (state == AgentReportState::failed) {
        return AgentStatus::failed;
      }

      return state == AgentReportState::blocked ? AgentStatus::blocked : AgentStatus::ready;
    }

  }

  bool AgentEvidence::expired(std::int64_t now) const noexcept {
    return expires_at <= now;
  }

  AgentEvidence AgentEvidence::process(AgentProvider provider, ObservationTime now) noexcept {
    return {.provider = provider, .status = AgentStatus::ready, .source = AgentSource::foreground_process, .confidence = certain_confidence, .observed = now, .expires_at = std::numeric_limits<std::int64_t>::max()};
  }

  AgentEvidence AgentEvidence::screen(AgentProvider provider, AgentSignal signal, ObservationTime now) noexcept {
    return {.provider = provider, .status = signal.status, .source = AgentSource::screen, .confidence = signal.confidence, .observed = now, .expires_at = now.milliseconds + (signal.status == AgentStatus::working ? screen_working_expiry : settled_expiry).count()};
  }

  AgentEvidence AgentEvidence::report(AgentProvider provider, AgentReportState state, ObservationTime now) noexcept {
    return {.provider = provider, .status = reportStatus(state), .source = AgentSource::lifecycle_report, .confidence = certain_confidence, .observed = now, .expires_at = now.milliseconds + reportExpiry(state).count()};
  }

  bool completionRequiresSignal(AgentProvider provider) noexcept {
    return provider == AgentProvider::codex || provider == AgentProvider::pi || provider == AgentProvider::cursor || provider == AgentProvider::opencode || provider == AgentProvider::antigravity;
  }

  bool containsInsensitive(std::string_view text, std::string_view phrase) noexcept {
    return !phrase.empty() && asciiFindIgnoreCase(text, phrase) != std::string_view::npos;
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

  template class ManifestTextList<AgentManifest::maximum_processes, AgentManifest::process_bytes>;
  template class ManifestTextList<AgentManifest::maximum_phrases, AgentManifest::phrase_bytes>;

  void AgentManifest::addCommandTool(std::string_view tool, std::string_view field) {
    if (tool.empty() || tool.size() > AgentCommandTool::tool_bytes || field.empty() || field.size() > AgentCommandTool::field_bytes || tool_count == command_tools.size()) {
      throw EncodingError{"Invalid agent command tool"};
    }

    command_tools.atMut(tool_count).tool.assign(tool);
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

  tbc::val_a<std::string_view> AgentManifest::placeholderTitle(tbc::mut_a<FixedText<placeholder_bytes>> storage) const {
    if (!placeholder.view().empty()) {
      return placeholder.view();
    }

    constexpr std::string_view prefix = "New ";
    constexpr std::string_view suffix = " session";

    ds::Array<char, placeholder_bytes> bytes{};
    const auto display = displayName();
    const auto title = bytes.viewMut();

    std::ranges::copy(prefix, title.begin());
    std::ranges::copy(display, title.subspan(prefix.size()).begin());
    std::ranges::copy(suffix, title.subspan(prefix.size() + display.size()).begin());
    storage.assign({bytes.data(), prefix.size() + display.size() + suffix.size()});
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
    if (name.empty() || name.size() > AgentManifest::name_bytes || !std::ranges::all_of(name, [](char byte) {
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

  ds::Option<AgentSignal> AgentManifests::detect(std::string_view text, AgentProvider provider) const noexcept {
    if (provider != AgentProvider::unknown) {
      const auto* entry = find(provider);
      if (entry == nullptr) {
        return ds::none;
      }

      if (entry->blocked.matches(text)) {
        return AgentSignal{.provider = provider, .status = AgentStatus::blocked, .confidence = blocked_confidence};
      }

      if (entry->working.matches(text)) {
        return AgentSignal{.provider = provider, .status = AgentStatus::working, .confidence = working_confidence};
      }

      if (entry->ready_prompt.matches(text)) {
        return AgentSignal{.provider = provider, .status = AgentStatus::ready, .confidence = ready_prompt_confidence, .identity_confirmed = true, .ready_confirmed = true};
      }

      return entry->identity.matches(text) ? ds::Option{AgentSignal{.provider = provider, .status = AgentStatus::ready, .confidence = identity_confidence, .identity_confirmed = true, .ready_confirmed = false}} : ds::none;
    }

    for (const auto& entry : entries()) {
      if (entry.blocked.matches(text)) {
        return AgentSignal{.provider = inferProvider(text), .status = AgentStatus::blocked, .confidence = blocked_confidence};
      }
    }

    for (const auto& entry : entries()) {
      if (entry.working.matches(text)) {
        return AgentSignal{.provider = inferProvider(text), .status = AgentStatus::working, .confidence = working_confidence};
      }
    }

    for (const auto& entry : entries()) {
      if (entry.ready_prompt.matches(text)) {
        return AgentSignal{.provider = entry.provider, .status = AgentStatus::ready, .confidence = ready_prompt_confidence, .identity_confirmed = true, .ready_confirmed = true};
      }
    }

    for (const auto& entry : entries()) {
      if (entry.identity.matches(text)) {
        return AgentSignal{.provider = entry.provider, .status = AgentStatus::ready, .confidence = identity_confidence, .identity_confirmed = true, .ready_confirmed = false};
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

    for (const auto provider : built_in_agent_providers) {
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
    claude.process_paths.append(R"(\@anthropic-ai\claude-code\)");
    claude.brand.append("claude");
    claude.identity.append("claude code");
    claude.addCommandTool("Bash", "command");
    claude.interrupt = AgentInterruptKey::control_c;
    // The footers of Claude Code's dialogs: a permission, a question and the workspace's trust.
    for (const auto* const phrase : {"esc to cancel \u00b7 tab to amend", "enter to select \u00b7 \u2191/\u2193 to navigate", "enter to confirm \u00b7 esc to cancel", "press enter to confirm", "enter to submit answer", "enter to select", "allow command?", "[y/n]", "do you want to proceed?", "waiting for permission", "yes, and don't ask again"}) {
      claude.blocked.append(phrase);
    }

    for (const auto* const phrase : {"esc to interrupt", "working (", "waiting for background agents", "tasks still running", "background shells"}) {
      claude.working.append(phrase);
    }

    auto& codex = table.add("codex");

    codex.process_paths.append("/@openai/codex/");
    codex.process_paths.append(R"(\@openai\codex\)");
    codex.brand.append("codex");
    codex.ready_prompt.append("ask codex to do anything");
    // The footer of Codex's approval of a command or an edit.
    codex.blocked.append("press enter to confirm or esc to cancel");
    codex.addCommandTool("Bash", "command");
    codex.addCommandTool("exec_command", "cmd");
    codex.addCommandTool("shell", "command");

    auto& pi_agent = table.add("pi");

    pi_agent.process_paths.append("/@earendil-works/pi-coding-agent/");
    pi_agent.process_paths.append(R"(\@earendil-works\pi-coding-agent\)");
    pi_agent.process_paths.append("/@mariozechner/pi-coding-agent/");
    pi_agent.process_paths.append(R"(\@mariozechner\pi-coding-agent\)");
    pi_agent.addCommandTool("bash", "command");

    auto& cursor = table.add("cursor");

    cursor.process_paths.append("/cursor-agent/versions/");
    cursor.addCommandTool("Shell", "command");
    for (const auto* const phrase : {"not in allowlist:", "skip & tell the agent what to do instead", "yes, build locally", "do you trust the contents of this directory?"}) {
      cursor.blocked.append(phrase);
    }

    auto& opencode = table.add("opencode");

    opencode.interrupt = AgentInterruptKey::escape_twice;
    opencode.addCommandTool("bash", "command");

    auto& antigravity = table.add("antigravity");

    antigravity.addCommandTool("run_command", "CommandLine");
    // Antigravity's dialogs, by their footers: a command, an edit, the workspace's trust, and the
    // bare one of a file outside the workspace, right above Antigravity's own footer. Its menus
    // name other keys after "navigate", and no menu offers to deny.
    for (const auto* const phrase : {"\u2191/\u2193 navigate \u00b7 tab amend", "\u2191/\u2193 navigate \u00b7 f full diff", "\u2191/\u2193 navigate \u00b7 enter confirm", "\u2191/\u2193 navigate esc to cancel", "no, deny"}) {
      antigravity.blocked.append(phrase);
    }

    return table;
  }

  const AgentManifests& builtinManifests() {
    static const AgentManifests manifests = makeBuiltinManifests();

    return manifests;
  }

  void HistoryPatternList::reserve() {
    if (count_ + expression_count_ == maximum_patterns) {
      throw std::length_error{"History filter exceeds 64 patterns"};
    }
  }

  void HistoryPatternList::append(std::string_view pattern) {
    if (pattern.empty() || pattern.contains('\0')) {
      throw std::invalid_argument{"History filter patterns must not be empty or contain NUL"};
    }

    reserve();
    patterns_.atMut(count_).assign(pattern);
    ++count_;
  }

  void HistoryPatternList::appendExpression(std::string_view pattern) {
    reserve();
    if (expression_count_ == maximum_expressions) {
      throw std::length_error{"History filter exceeds 16 regular expressions"};
    }

    // A filter's expression is as long as its texts may be.
    if (pattern.empty() || pattern.size() > pattern_bytes) {
      throw std::invalid_argument{"History filter regex must hold 1 to 256 bytes"};
    }

    try {
      expressions_.atMut(expression_count_) = Pattern{pattern, PatternOptions{.regex = true}};
    } catch (const PatternError& error) {
      constexpr std::size_t message_bytes = 160;
      ds::Array<char, message_bytes> message{};

      std::format_to_n(message.dataMut(), message.size() - 1, "History filter regex: {}", error.what());
      throw std::invalid_argument{message.data()};
    }

    ++expression_count_;
  }

  bool HistoryPatternList::matches(std::string_view text) const noexcept {
    const auto contains = [text](const auto& pattern) {
      return text.contains(pattern.view());
    };

    const auto searches = [text](const Pattern& pattern) {
      return pattern.matches(text);
    };

    return std::ranges::any_of(std::span{patterns_}.first(count_), contains) || std::ranges::any_of(std::span{expressions_}.first(expression_count_), searches);
  }

  const HistoryFilters& defaultHistoryFilters() noexcept {
// The defaults live as long as the process, as the references its callers keep do.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wexit-time-destructors"
    static const HistoryFilters filters{};
#pragma clang diagnostic pop

    return filters;
  }

  void HistoryCommandList::append(std::string_view command) {
    if (command.empty() || command.size() > HistoryPatternList::pattern_bytes || command.contains('\0')) {
      throw std::invalid_argument{"Trivial commands must be 1..256 bytes without NUL"};
    }

    if (count_ == maximum_commands) {
      throw std::length_error{"History trivial commands exceed 64 entries"};
    }

    commands_.atMut(count_).assign(command);
    ++count_;
  }

  bool HistoryCommandList::contains(std::string_view command) const noexcept {
    constexpr std::string_view blanks = " \t\r\n";
    const auto first = command.find_first_not_of(blanks);
    if (first == std::string_view::npos) {
      return false;
    }

    command.remove_suffix(command.size() - command.find_last_not_of(blanks) - 1);
    command.remove_prefix(first);
    return std::ranges::any_of(std::span{commands_}.first(count_), [command](const auto& entry) {
      return entry.view() == command;
    });
  }

  void HistoryFilters::addTrivial(std::string_view command) {
    trivial_commands.append(command);
  }

  HistoryVerdict HistoryFilters::verdict(std::string_view command, std::string_view directory, bool redact) const noexcept {
    if (command.empty() || trivial_commands.contains(command) || commands.matches(command) || directories.matches(directory)) {
      return HistoryVerdict::drop;
    }

    if (!redact || !secrets) {
      return HistoryVerdict::keep;
    }

    std::size_t token_bytes = 0;
    bool found = false;

    for (auto span = findSecret(command); span; span = findSecret(command, span->end)) {
      found = true;
      if (span->kind == SecretKind::token) {
        token_bytes += span->end - span->begin;
      }
    }

    if (!found) {
      return HistoryVerdict::keep;
    }

    // A command that is mostly a key, as one pasted at the prompt, is the key: nothing of it is
    // worth keeping. One that uses a key keeps the rest of what it did.
    const auto written = static_cast<std::size_t>(std::ranges::count_if(command, [](char byte) {
      return byte != ' ' && byte != '\t' && byte != '\n';
    }));

    return token_bytes * 2 > written ? HistoryVerdict::drop : HistoryVerdict::redact;
  }

  tbc::val_a<FilteredCommand> HistoryFilters::filter(tbc::val_a<std::string_view> command, std::string_view directory, tbc::val_a<std::span<char>> scratch, bool redact) const noexcept {
    const auto decided = verdict(command, directory, redact);
    if (decided != HistoryVerdict::redact) {
      return {.verdict = decided, .text = decided == HistoryVerdict::keep ? command : std::string_view{}};
    }

    const auto redacted = redactSecrets(command, scratch);
    if (!redacted) {
      return {.verdict = HistoryVerdict::drop};
    }

    return {.verdict = HistoryVerdict::redact, .text = {scratch.data(), redacted->bytes}};
  }

  tbc::val_a<FilteredCommand> HistoryFilters::filterPane(tbc::val_a<std::string_view> command, std::string_view directory, tbc::val_a<std::span<char>> scratch) const noexcept {
    if (!command.empty() && command.front() == ' ') {
      return {.verdict = HistoryVerdict::drop};
    }

    return filter(command, directory, scratch, true);
  }

  tbc::val_a<FilteredCommand> HistoryFilters::filterAgent(tbc::val_a<std::string_view> command, std::string_view directory, tbc::val_a<std::span<char>> scratch) const noexcept {
    return filter(command, directory, scratch, true);
  }

  tbc::val_a<std::string_view> HistoryFilters::filterOutput(tbc::val_a<std::string_view> output, tbc::val_a<std::span<char>> scratch, std::size_t limit) const noexcept {
    if (!secrets || !findSecret(output)) {
      return output;
    }

    // A redaction that does not fit keeps none of the output rather than a secret of it.
    const auto redacted = redactSecrets(output, scratch);
    if (!redacted) {
      return {};
    }

    std::string_view text{scratch.data(), redacted->bytes};

    if (text.size() > limit) {
      text.remove_prefix(text.size() - limit);
      while (!text.empty() && utf8::isContinuation(static_cast<std::uint8_t>(text.front()))) {
        text.remove_prefix(1);
      }
    }

    return text;
  }

  bool HistoryFilters::recordsPane(std::string_view command, std::string_view directory) const noexcept {
    return !command.empty() && command.front() != ' ' && verdict(command, directory, true) != HistoryVerdict::drop;
  }

  bool HistoryFilters::recordsAgent(std::string_view command, std::string_view directory) const noexcept {
    return verdict(command, directory, true) != HistoryVerdict::drop;
  }

  bool HistoryFilters::allowsPane(std::string_view command, std::string_view directory) const noexcept {
    return !command.empty() && command.front() != ' ' && verdict(command, directory, true) == HistoryVerdict::keep;
  }

  bool HistoryFilters::allowsAgent(std::string_view command, std::string_view directory, bool redact) const noexcept {
    return verdict(command, directory, redact) == HistoryVerdict::keep;
  }

  bool HistoryFilters::looksLikeSecret(std::string_view command) noexcept {
    return findSecret(command).hasValue();
  }

}

namespace telar::runtime::config {

  void readHistoryFilters(const lua::Value& history, HistoryFilters& filters) {
    if (!history.present()) {
      return;
    }

    // A string is text the command or directory contains; `{ regex = "..." }` an expression it
    // matches, which a fault refuses the configuration with.
    const auto patterns = [](const lua::Value& field, HistoryPatternList& destination) {
      if (!field.present()) {
        return;
      }

      const auto count = field.arraySize();

      for (std::size_t index = 1; index <= count; ++index) {
        const auto entry = field.element(static_cast<lua_Integer>(index));
        if (!entry.is(LUA_TTABLE)) {
          destination.append(entry.string());
          continue;
        }

        entry.onlyFields({"regex"});
        const auto expression = entry.field("regex");

        try {
          destination.appendExpression(expression.string());
        } catch (const std::invalid_argument& error) {
          expression.fail(error.what());
        }
      }
    };

    filters.secrets = history.field("secrets_filter").boolean(filters.secrets);
    patterns(history.field("command_filters"), filters.commands);
    patterns(history.field("cwd_filters"), filters.directories);
    const auto trivial = history.field("trivial_commands");
    if (trivial.present()) {
      const auto count = trivial.arraySize();

      for (std::size_t index = 1; index <= count; ++index) {
        filters.addTrivial(trivial.element(static_cast<lua_Integer>(index)).string());
      }
    }

    filters.store_failed = history.field("store_failed").boolean(filters.store_failed);
    if (const auto retention = history.field("retention"); retention.present()) {
      constexpr std::uint64_t mebibyte = std::uint64_t{1} << 20U;
      constexpr std::uint64_t maximum_rows = std::uint64_t{1} << 40U;
      constexpr std::uint64_t maximum_days = std::uint64_t{100} * 365;
      constexpr std::uint64_t maximum_output_mib = std::uint64_t{1} << 20U;
      constexpr std::uint64_t maximum_keep_runs = 1'000'000;
      auto& kept = filters.retention;

      retention.onlyFields({"max_rows", "max_age_days", "max_output_mib", "keep_runs"});
      kept.max_rows = retention.field("max_rows").boundedInteger(kept.max_rows, {.minimum = 0, .maximum = maximum_rows});
      kept.max_age_days = static_cast<std::uint32_t>(retention.field("max_age_days").boundedInteger(kept.max_age_days, {.minimum = 0, .maximum = maximum_days}));
      kept.max_output_bytes = retention.field("max_output_mib").boundedInteger(kept.max_output_bytes / mebibyte, {.minimum = 0, .maximum = maximum_output_mib}) * mebibyte;
      kept.keep_runs = static_cast<std::uint32_t>(retention.field("keep_runs").boundedInteger(kept.keep_runs, {.minimum = 0, .maximum = maximum_keep_runs}));
    }
  }

}

namespace telar::runtime {

  bool ProxyCaptureLimits::valid() const noexcept {
    return part_bytes != 0 && exchange_bytes >= 2 && total_bytes != 0 && part_bytes <= exchange_bytes && exchange_bytes <= total_bytes && exchange_bytes <= maximum_exchange_bytes && total_bytes <= maximum_total_bytes && join_timeout.count() > 0 && join_timeout <= maximum_join_timeout;
  }

  template <Allocator Memory>
  ProxyHostPolicy<Memory>::ProxyHostPolicy(tbc::mut_a<Memory> memory)
      : patterns_(memory) {}

  template <Allocator Memory>
  tbc::val_a<ProxyHostPolicy<Memory>> ProxyHostPolicy<Memory>::clone() const {
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

    ds::Array<char, maximum_hostname_bytes + wildcard_prefix.size()> canonical; // NOLINT(cppcoreguidelines-pro-type-member-init): checked for every proxied host; nothing reads a byte before it is written.
    const auto bytes = canonical.viewMut();

    std::ranges::transform(hostname, bytes.subspan(wildcard_prefix.size()).begin(), asciiLower);
    const auto exact = bytes.subspan(wildcard_prefix.size(), hostname.size());
    if (find({exact.data(), exact.size()})) {
      return true;
    }

    for (auto dot = hostname.find('.'); dot != std::string_view::npos; dot = hostname.find('.', dot + 1)) {
      const auto start = dot + 1;
      const auto candidate = bytes.subspan(start, hostname.size() - start + wildcard_prefix.size());

      std::ranges::copy(wildcard_prefix, candidate.begin());
      if (find({candidate.data(), candidate.size()})) {
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
  ProxyOptions<Memory>::ProxyOptions(tbc::mut_a<Memory> memory)
      : authority_directory(memory),
        intercept_hosts(memory) {}

  template <Allocator Memory>
  tbc::val_a<ProxyOptions<Memory>> ProxyOptions<Memory>::clone() const {
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

      std::ranges::copy(text, policy.answerback.viewMut().begin());
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
    return field.boundedInteger(fallback, {.minimum = 1, .maximum = std::numeric_limits<std::size_t>::max()});
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
  CommandValues<Memory>::CommandValues(tbc::mut_a<Memory> memory)
      : arguments(memory) {}

  template <Allocator Memory>
  tbc::val_a<CommandValues<Memory>> CommandValues<Memory>::clone() const {
    CommandValues copy{arguments.memory()};

    copy.arguments = arguments.clone();
    copy.timeout = timeout;
    copy.idle_timeout = idle_timeout;
    return copy;
  }

  template <Allocator Memory>
  CommandValues<Memory>::Views CommandValues<Memory>::views() const noexcept {
    Views views;

    for (const auto& argument : arguments) {
      views.words.atMut(views.count++) = argument;
    }

    return views;
  }

  template <Allocator Memory>
  RuntimeValues<Memory>::RuntimeValues(tbc::mut_a<Memory> memory)
      : history_path(memory),
        session_path(memory),
        engine(memory),
        descriptions(memory),
        proxy(memory) {}

  template <Allocator Memory>
  tbc::val_a<RuntimeValues<Memory>> RuntimeValues<Memory>::clone() const {
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
    copy.agent_plans = agent_plans;
    copy.shell_completion = shell_completion;
    copy.shell_completion_rc = shell_completion_rc;
    return copy;
  }

  template struct CommandValues<Memory>;
  template struct CommandValues<ConcurrentMemory>;
  template struct RuntimeValues<Memory>;
  template struct RuntimeValues<ConcurrentMemory>;

}

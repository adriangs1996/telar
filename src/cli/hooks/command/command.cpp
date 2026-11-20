module telar.cli.hooks.command;

import telar.config.core;
import telar.base.text.utf8;
import telar.config.runtime;
import telar.base.ds;

namespace telar::runtime::cli::hooks {

  namespace {

    // The runtime takes a session reference of at most this many bytes.
    constexpr std::size_t maximum_session_reference = 64;

    // Reads each named field as text, so a field of another type fails the payload.
    void readTexts(const Object& fields, std::initializer_list<std::string_view> names) {
      for (const auto name : names) {
        static_cast<void>(fields.text(name));
      }
    }

    // Cursor spells its tool events as camelCase; the reports take the PascalCase names.
    std::string_view cursorToolEvent(std::string_view name) noexcept {
      if (name == "preToolUse") {
        return "PreToolUse";
      }

      if (name == "postToolUse" || name == "postToolUseFailure") {
        return "PostToolUse";
      }

      return name;
    }

    // A string token holding a \u escape decodes as JSON would, so an invalid one fails here.
    void decodeEscapes(std::string_view token, ds::String<Memory>& decoded) {
      if (token.contains("\\u")) {
        JsonValue{token}.string(decoded);
      }
    }

  }

  bool printable(unsigned char byte) noexcept {
    // The bytes below the space and the delete byte are control characters.
    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char delete_byte = 0x7f;

    return byte >= first_printable && byte != delete_byte;
  }

  Object::Object(Memory& memory, JsonValue value, bool reject_duplicates)
      : memory_(memory),
        members_(memory),
        reject_duplicates_(reject_duplicates) {
    if (!value.encoded().starts_with('{')) {
      throw std::invalid_argument{"Expected hook object"};
    }

    value.eachMember([&](JsonValue key, JsonValue entry) {
      ds::String<Memory> name{memory_};

      key.string(name);
      members_.push(Member{.name = std::move(name), .value = entry, .text = ds::none, .position = members_.size()});
    });

    indexMembers();
    decodeStrings();
  }

  ds::Option<JsonValue> Object::value(std::string_view name) const {
    const auto* member = find(name);
    if (member != nullptr) {
      checkUnique(*member);
    }

    return member == nullptr ? ds::none : ds::Option{member->value};
  }

  ds::Option<std::string_view> Object::optionalText(std::string_view name) const {
    const auto* member = find(name);
    if (member == nullptr) {
      return ds::none;
    }

    checkUnique(*member);
    if (member->value.encoded() == "null") {
      return ds::none;
    }

    return decoded(*member);
  }

  std::string_view Object::text(std::string_view name) const {
    const auto* member = find(name);

    return member == nullptr ? std::string_view{} : decoded(*member);
  }

  ds::Option<std::string_view> Object::stringField(std::string_view name) const {
    const auto field = value(name);

    return field && field->encoded().starts_with('"') ? optionalText(name) : ds::none;
  }

  ds::Option<bool> Object::boolean(std::string_view name) const {
    const auto field = value(name);
    if (!field || field->encoded() == "null") {
      return ds::none;
    }

    if (field->encoded() != "true" && field->encoded() != "false") {
      throw std::invalid_argument{"Expected hook boolean"};
    }

    return field->boolean();
  }

  void Object::requireUnique() const {
    for (const auto& member : members_) {
      if (member.duplicate) {
        throw std::invalid_argument{"Duplicate hook field"};
      }
    }
  }

  template <typename Consumer>
  void Object::eachValue(const Consumer& consume) const {
    for (const auto& member : members_) {
      consume(member.value);
    }
  }

  auto Object::find(std::string_view name) const noexcept -> const Member* {
    const auto members = members_.view();
    const auto found = std::ranges::lower_bound(members, name, std::ranges::less{}, [](const Member& member) {
      return std::string_view{member.name};
    });

    return found != members.end() && found->name == name ? &*found : nullptr;
  }

  void Object::indexMembers() {
    std::ranges::sort(members_.viewMut(), [](const Member& left, const Member& right) {
      return left.name == right.name ? left.position < right.position : left.name < right.name;
    });

    std::size_t unique = 0;

    for (std::size_t index = 0; index < members_.size(); ++index) {
      if (unique != 0 && members_[unique - 1].name == members_[index].name) {
        members_.atMut(unique - 1) = std::move(members_.atMut(index));
        members_.atMut(unique - 1).duplicate = true;
      } else {
        if (unique != index) {
          members_.atMut(unique) = std::move(members_.atMut(index));
        }

        ++unique;
      }
    }

    members_.truncate(unique);
  }

  void Object::decodeStrings() {
    for (auto& member : members_.viewMut()) {
      if (member.value.encoded().starts_with('"')) {
        ds::String<Memory> decoded{memory_};

        member.value.string(decoded);
        member.text = std::move(decoded);
      }
    }
  }

  tbc::val_a<std::string_view> Object::decoded(tbc::ref_a<Member> member) const {
    checkUnique(member);
    if (!member.text) {
      // Not a string: reading it as one fails as it always did.
      ds::String<Memory> failed{memory_};

      member.value.string(failed);
      return {};
    }

    return *member.text;
  }

  void Object::checkUnique(const Member& member) const {
    if (reject_duplicates_ && member.duplicate) {
      throw std::invalid_argument{"Duplicate hook field"};
    }
  }

  Payload::Payload(Memory& memory, AgentProvider provider, JsonValue input)
      : Payload(memory, provider, Object{memory, input, true}) {}

  Payload::Payload(Memory& memory, AgentProvider provider, Object input)
      : memory_(memory),
        provider_(provider),
        fields_(std::move(input)),
        tools_(memory, toolObject(fields_)) {
    validateTools();
    readTexts(fields_, {"tool_name", "cwd"});
    if (provider == AgentProvider::pi || provider == AgentProvider::opencode) {
      readEventFields();
    } else {
      readHookFields();
    }
  }

  void Payload::validateTools() {
    if (const auto tool_input = fields_.value("tool_input")) {
      if (tool_input->encoded().starts_with('{')) {
        tools_.requireUnique();
        tools_.eachValue([&](JsonValue child) {
          validateDynamicValue(memory_, child);
        });
      } else {
        validateDynamicValue(memory_, *tool_input);
      }
    }
  }

  void Payload::readEventFields() {
    readTexts(fields_, {"event", "session_id", "tool_call_id"});
    static_cast<void>(fields_.template integer<std::int32_t>("exit_code"));
    if (provider_ == AgentProvider::pi) {
      static_cast<void>(fields_.boolean("idle"));
      strictBoolean("blocked");
      static_cast<void>(fields_.optionalText("name"));
    } else {
      strictBoolean("busy");
      static_cast<void>(fields_.optionalText("title"));
      static_cast<void>(blockedReason());
    }
  }

  void Payload::readHookFields() {
    readTexts(fields_, {"hook_event_name", "tool_use_id"});
    if (provider_ == AgentProvider::cursor) {
      readCursorFields();
      return;
    }

    static_cast<void>(fields_.optionalText("agent_id"));
    readTexts(fields_, {"session_id", "transcript_path"});
    if (provider_ == AgentProvider::claude) {
      readClaudeFields();
      return;
    }

    readTexts(fields_, {"source", "state_database"});
    static_cast<void>(fields_.optionalText("last_assistant_message"));
    static_cast<void>(fields_.template integer<std::size_t>("running_subagents"));
  }

  void Payload::readCursorFields() {
    readTexts(fields_, {"conversation_id", "tool_output", "chat_meta"});
    if (const auto roots = fields_.value("workspace_roots")) {
      roots->eachElement([&](JsonValue root) {
        ds::String<Memory> decoded{memory_};

        root.string(decoded);
        if (!workspace_) {
          workspace_ = std::move(decoded);
        }
      });
    }
  }

  void Payload::readClaudeFields() {
    readTexts(fields_, {"session_title", "notification_type", "message", "last_assistant_message", "new_cwd"});
    if (const auto tasks = fields_.value("background_tasks")) {
      tasks->eachElement([&](JsonValue value) {
        const Object task{memory_, value, true};
        const auto type = task.text("type");
        const auto status = task.text("status");

        running_subagents_ += type == "subagent" && status == "running";
      });
    }
  }

  Memory& Payload::memory() const noexcept {
    return memory_;
  }

  AgentProvider Payload::provider() const noexcept {
    return provider_;
  }

  const Object& Payload::fields() const noexcept {
    return fields_;
  }

  const Object& Payload::tools() const noexcept {
    return tools_;
  }

  std::size_t Payload::runningSubagents() const noexcept {
    return running_subagents_;
  }

  void Payload::setRunningSubagents(std::size_t count) noexcept {
    running_subagents_ = count;
  }

  std::string_view Payload::event() const {
    return fields_.text(provider_ == AgentProvider::pi || provider_ == AgentProvider::opencode ? "event" : "hook_event_name");
  }

  std::string_view Payload::session() const {
    return fields_.text(provider_ == AgentProvider::cursor ? "conversation_id" : "session_id");
  }

  bool Payload::subagent() const {
    return !fields_.optionalText("agent_id").valueOr("").empty();
  }

  std::string_view Payload::workspace() const noexcept {
    return workspace_ ? std::string_view{*workspace_} : std::string_view{};
  }

  std::string_view Payload::toolEvent() const {
    return provider_ == AgentProvider::cursor ? cursorToolEvent(event()) : event();
  }

  AgentBlockedReason Payload::blockedReason() const {
    const auto name = fields_.value("blocked") ? fields_.text("blocked") : "none";
    constexpr ds::Array names{"none", "permission", "question", "plan", "other"};
    const auto* const found = std::ranges::find(names, name);
    if (found == names.end()) {
      throw std::invalid_argument{"Unknown hook blocked reason"};
    }

    return static_cast<AgentBlockedReason>(found - names.begin());
  }

  void Payload::strictBoolean(std::string_view name) {
    if (fields_.value(name) && !fields_.boolean(name).hasValue()) {
      throw std::invalid_argument{"Expected hook boolean"};
    }
  }

  JsonValue Payload::toolObject(const Object& fields) {
    const auto value = fields.value("tool_input");

    return value && value->encoded().starts_with('{') ? *value : JsonValue{"{}"};
  }

  void validateUnicodeEscapes(Memory& memory, std::string_view input) {
    if (!input.contains("\\u")) {
      return;
    }

    ds::String<Memory> decoded{memory};
    ds::Option<std::size_t> start;

    for (std::size_t index = 0; index < input.size(); ++index) {
      if (start && input[index] == '\\') {
        ++index;
      } else if (input[index] == '"' && start) {
        decodeEscapes(input.substr(*start, index - *start + 1), decoded);
        start.reset();
      } else if (input[index] == '"') {
        start = index;
      }
    }
  }

  void validateDynamicValue(Memory& memory, JsonValue value) {
    // Depth first and in the order a recursive walk takes, so the first failure is the same one.
    ds::Vec<JsonValue, Memory> pending{memory};

    pending.push(value);
    while (const auto current = pending.pop()) {
      const auto children = pending.size();
      const auto push = [&](JsonValue child) {
        pending.push(child);
      };

      if (current->encoded().starts_with('{')) {
        const Object fields{memory, *current};

        fields.requireUnique();
        fields.eachValue(push);
      } else if (current->encoded().starts_with('[')) {
        current->eachElement(push);
      }

      std::ranges::reverse(pending.viewMut().subspan(children));
    }
  }

  std::string_view sessionReference(std::string_view text) noexcept {
    if (text.empty() || text.size() > maximum_session_reference || text.front() == '-') {
      return {};
    }

    for (const char byte : text) {
      const bool allowed = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '_' || byte == '-' || byte == ':';
      if (!allowed) {
        return {};
      }
    }

    return text;
  }

  std::string_view validPrefix(std::string_view text) noexcept {
    while (!text.empty()) {
      try {
        validateUtf8(text);
        return text;
      } catch (const EncodingError&) {
        text.remove_suffix(1);
      }
    }

    return {};
  }

  template <std::size_t Capacity>
  void displayText(FixedText<Capacity>& output, std::string_view text, bool multiline) {
    ds::Array<char, Capacity> bytes;
    std::size_t length = 0;

    for (const char character : text) {
      const auto byte = static_cast<unsigned char>(character);
      if (length == bytes.size() || (!multiline && byte == '\n')) {
        break;
      }

      if (printable(byte) || (multiline && (byte == '\n' || byte == '\t'))) {
        bytes.atMut(length++) = static_cast<char>(byte);
      }
    }

    std::string_view result{bytes.data(), length};

    if (multiline) {
      const auto first = result.find_first_not_of(" \n\t");

      result = first == std::string_view::npos ? std::string_view{} : result.substr(first, result.find_last_not_of(" \n\t") - first + 1);
    }

    output.assign(validPrefix(result));
  }

  void eventLine(FixedText<display_line_bytes>& output, std::string_view text) {
    const auto* const control = std::ranges::find_if(text, [](unsigned char byte) {
      return !printable(byte);
    });

    const auto prefix = utf8Prefix(text.substr(0, static_cast<std::size_t>(control - text.begin())), display_line_bytes);

    try {
      validateUtf8(prefix);
      output.assign(prefix);
    } catch (const EncodingError&) {
      output.assign({});
    }
  }

  bool defaultOpenCodeTitle(std::string_view title) noexcept {
    constexpr std::string_view shape = "0000-00-00T00:00:00.000Z";

    for (const auto prefix : {std::string_view{"New session - "}, std::string_view{"Child session - "}}) {
      if (!title.starts_with(prefix) || title.size() != prefix.size() + shape.size()) {
        continue;
      }

      title.remove_prefix(prefix.size());
      for (std::size_t index = 0; index < shape.size(); ++index) {
        if (shape[index] == '0' ? title[index] < '0' || title[index] > '9' : title[index] != shape[index]) {
          return false;
        }
      }

      return true;
    }

    return false;
  }

  void toolEvent(FixedText<display_line_bytes>& output, const Payload& input) {
    const auto name = input.fields().text("tool_name");
    if (name.empty()) {
      output.assign({});
      return;
    }

    ds::Array<char, 192> buffer{};
    std::size_t length = 0;
    const auto append = [&](std::string_view text) {
      const auto count = std::min(text.size(), buffer.size() - length);

      std::ranges::copy(text.substr(0, count), buffer.viewMut().subspan(length).begin());
      length += count;
    };

    append("» ");
    append(name);
    for (const auto* const key : {"command", "cmd", "file_path", "filePath", "filepath", "path", "pattern", "url", "query", "prompt", "description"}) {
      if (const auto argument = input.tools().stringField(key); argument && !argument->empty()) {
        append(" ");
        append(*argument);
        break;
      }
    }

    eventLine(output, {buffer.data(), length});
  }

  bool questionEvent(FixedText<display_line_bytes>& output, const Payload& input) {
    const auto questions = input.tools().value("questions");
    if (!questions || !questions->encoded().starts_with('[')) {
      return false;
    }

    bool first = true;
    bool found = false;

    questions->eachElement([&](JsonValue value) {
      if (!std::exchange(first, false) || !value.encoded().starts_with('{')) {
        return;
      }

      const Object question{input.memory(), value};
      if (const auto text = question.stringField("question"); text && !text->empty()) {
        eventLine(output, *text);
        found = true;
      }
    });

    return found;
  }

  namespace {

    ds::Option<std::int32_t> commandExitCode(const Payload& input) {
      if (input.provider() == AgentProvider::claude) {
        return input.event() == "PostToolUse" ? ds::Option<std::int32_t>{0} : ds::none;
      }

      if (input.provider() == AgentProvider::codex) {
        return ds::none;
      }

      if (input.provider() != AgentProvider::cursor) {
        return input.fields().template integer<std::int32_t>("exit_code");
      }

      if (input.event() != "postToolUse" || input.fields().text("tool_name") != "Shell") {
        return ds::none;
      }

      try {
        const Object output{input.memory(), JsonValue::parse(input.fields().text("tool_output")), true};

        return output.template integer<std::int32_t>("exitCode");
      } catch (const std::exception&) {
        return ds::none;
      }
    }

  }

  ds::Option<ReportAgentCommand> commandReport(const Payload& input) {
    if ((input.provider() == AgentProvider::claude || input.provider() == AgentProvider::codex) && input.subagent()) {
      return ds::none;
    }

    const auto event = input.toolEvent();
    const bool started = event == "PreToolUse" || event == "tool_execution_start" || event == "tool.execute.before";
    const bool finished = event == "PostToolUse" || event == "tool_execution_end" || event == "tool.execute.after";
    if (!started && !finished) {
      return ds::none;
    }

    const auto provider = describeProvider(input.provider()).name;
    const auto* manifest = builtinManifests().find(input.provider());
    const auto field = manifest == nullptr ? std::string_view{} : manifest->commandField(input.fields().text("tool_name"));
    const auto command = input.tools().stringField(field);
    if (!command || command->empty()) {
      return ds::none;
    }

    const auto cwd = input.fields().text("cwd");

    return ReportAgentCommand{
        .phase = started ? AgentCommandPhase::started : AgentCommandPhase::finished,
        .provider = provider,
        .tool_call_id = input.fields().text(input.provider() == AgentProvider::pi || input.provider() == AgentProvider::opencode ? "tool_call_id" : "tool_use_id"),
        .command = *command,
        .cwd = input.provider() == AgentProvider::cursor && cwd.empty() ? input.workspace() : cwd,
        .session = sessionReference(input.session()),
        .exit_code = started ? ds::none : commandExitCode(input),
    };
  }

  void backgroundEvent(FixedText<display_line_bytes>& output, std::size_t count) {
    ds::Array<char, display_line_bytes> buffer{};
    const auto written = std::format_to_n(buffer.dataMut(), static_cast<std::ptrdiff_t>(buffer.size()), "waiting for {} background {}", count, count == 1 ? "agent" : "agents");

    output.assign({buffer.data(), std::min(static_cast<std::size_t>(written.size), buffer.size())});
  }

  template void displayText<display_line_bytes>(FixedText<display_line_bytes>& output, std::string_view text, bool multiline);
  template void displayText<display_message_bytes>(FixedText<display_message_bytes>& output, std::string_view text, bool multiline);

}

namespace telar::runtime::cli {

  HookOptions HookOptions::parse(std::span<char* const> arguments) {
    if (arguments.empty()) {
      throw std::invalid_argument{"Missing hook agent"};
    }

    ds::Option<AgentProvider> provider;

    for (const auto candidate : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
      if (describeProvider(candidate).name == arguments.front()) {
        provider = candidate;
      }
    }

    if (!provider) {
      throw std::invalid_argument{"Unknown hook agent"};
    }

    HookOptions options{.provider = *provider, .socket = {}};

    for (std::size_t index = 1; index < arguments.size(); index += 2) {
      if (std::string_view{arguments[index]} != "--socket" || index + 1 >= arguments.size()) {
        throw std::invalid_argument{"Unknown hook option"};
      }

      options.socket = arguments[index + 1];
    }

    return options;
  }

}

namespace telar::runtime::cli::hooks {

}

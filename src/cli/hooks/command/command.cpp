module;
#include "tbc/view.hpp"
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <new>

#include <cstdint>

#include <cstring>

module telar.cli.hooks.command;

namespace telar::runtime::cli::hooks {

  template <Allocator Memory>
  void validateUnicodeEscapes(Memory& memory, std::string_view input) {
    if (!input.contains("\\u")) {
      return;
    }

    String<Memory> decoded{AllocatorRef<char, Memory>{memory}};
    std::optional<std::size_t> start;

    for (std::size_t index = 0; index < input.size(); ++index) {
      if (start && input[index] == '\\') {
        ++index;
      } else if (input[index] == '"') {
        if (start) {
          const auto token = input.substr(*start, index - *start + 1);
          if (token.contains("\\u")) {
            JsonValue{token}.string(decoded);
          }

          start.reset();
        } else {
          start = index;
        }
      }
    }
  }

  template <Allocator Memory>
  void validateDynamicValue(Memory& memory, JsonValue value) {
    if (value.encoded().starts_with('{')) {
      Object fields{memory, value};

      fields.requireUnique();
      fields.eachValue([&](JsonValue child) {
        validateDynamicValue(memory, child);
      });
    } else if (value.encoded().starts_with('[')) {
      value.eachElement([&](JsonValue child) {
        validateDynamicValue(memory, child);
      });
    }
  }

  std::string_view sessionReference(std::string_view text) noexcept {
    if (text.empty() || text.size() > 64 || text.front() == '-') {
      return {};
    }

    for (const unsigned char byte : text) {
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

  void eventLine(FixedText<96>& output, std::string_view text) {
    const auto control = std::ranges::find_if(text, [](unsigned char byte) {
      return byte < 0x20 || byte == 0x7f;
    });

    const auto prefix = utf8Prefix(text.substr(0, static_cast<std::size_t>(control - text.begin())), 96);

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

  template <Allocator Memory>
  std::optional<std::int32_t> commandExitCode(Payload<Memory>& input) {
    if (input.provider == AgentProvider::claude) {
      return input.event() == "PostToolUse" ? std::optional<std::int32_t>{0} : std::nullopt;
    }

    if (input.provider == AgentProvider::codex) {
      return std::nullopt;
    }

    if (input.provider != AgentProvider::cursor) {
      return input.fields.template integer<std::int32_t>("exit_code");
    }

    if (input.event() != "postToolUse" || input.fields.text("tool_name") != "Shell") {
      return std::nullopt;
    }

    try {
      Object output{input.memory, JsonValue::parse(input.fields.text("tool_output")), true};

      return output.template integer<std::int32_t>("exitCode");
    } catch (const std::exception&) {
      return std::nullopt;
    }
  }

  template <Allocator Memory>
  std::optional<ReportAgentCommand> commandReport(Payload<Memory>& input) {
    if ((input.provider == AgentProvider::claude || input.provider == AgentProvider::codex) && input.subagent()) {
      return std::nullopt;
    }

    const auto event = input.toolEvent();
    const bool started = event == "PreToolUse" || event == "tool_execution_start" || event == "tool.execute.before";
    const bool finished = event == "PostToolUse" || event == "tool_execution_end" || event == "tool.execute.after";
    if (!started && !finished) {
      return std::nullopt;
    }

    const auto provider = describeProvider(input.provider).name;
    const auto* manifest = builtin_manifests.find(input.provider);
    const auto field = manifest == nullptr ? std::string_view{} : manifest->commandField(input.fields.text("tool_name"));
    const auto command = input.tools.stringField(field);
    if (!command || command->empty()) {
      return std::nullopt;
    }

    const auto cwd = input.fields.text("cwd");

    return ReportAgentCommand{
        .phase = started ? AgentCommandPhase::started : AgentCommandPhase::finished,
        .provider = provider,
        .tool_call_id = input.fields.text(input.provider == AgentProvider::pi || input.provider == AgentProvider::opencode ? "tool_call_id" : "tool_use_id"),
        .command = *command,
        .cwd = input.provider == AgentProvider::cursor && cwd.empty() ? input.workspace() : cwd,
        .session = sessionReference(input.session()),
        .exit_code = started ? std::nullopt : commandExitCode(input),
    };
  }

  void backgroundEvent(FixedText<96>& output, std::size_t count) {
    std::array<char, 96> buffer;
    const auto length = std::snprintf(buffer.data(), buffer.size(), "waiting for %zu background %s", count, count == 1 ? "agent" : "agents");

    output.assign({buffer.data(), static_cast<std::size_t>(length)});
  }

  template std::optional<ReportAgentCommand> commandReport<Memory>(Payload<Memory>& input);
  template void validateUnicodeEscapes<Memory>(Memory& memory, std::string_view input);
  template void validateDynamicValue<Memory>(Memory& memory, JsonValue value);

}

namespace telar::runtime::cli {

  HookOptions HookOptions::parse(std::span<char* const> arguments) {
    if (arguments.empty()) {
      throw std::invalid_argument{"Missing hook agent"};
    }

    std::optional<AgentProvider> provider;

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

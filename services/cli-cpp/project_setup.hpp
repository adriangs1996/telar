#pragma once

#include "execution.hpp"
#include "file_transfer.hpp"
#include "telar_base/text/json_node.hpp"
#include <cmath>

namespace telar::runtime::cli::project_setup {

inline constexpr std::size_t max_recipe_bytes = 32 * 1024;
inline constexpr std::chrono::seconds wait_timeout{600};

struct Options {
  std::string_view cwd;
  bool detach = false;

  static Options parse(Arguments words) {
    if (words.size() < 3 || std::string_view{words[0]} != "setup" || std::string_view{words[1]} != "--cwd") {
      throw std::invalid_argument{"InvalidProjectArguments"};
    }

    Options self{.cwd = words[2]};
    if (!self.cwd.starts_with('/')) {
      throw std::invalid_argument{"AbsoluteProjectPathRequired"};
    }

    for (const std::string_view word : words.subspan(3)) {
      if (word == "--detach") {
        self.detach = true;
      } else if (word != "--json") {
        throw std::invalid_argument{"UnknownProjectOption"};
      }
    }

    return self;
  }
};

// The shared JSON parser intentionally has one generic syntax error. A recipe
// keeps Zig's distinct EOF diagnostic when its valid prefix can be completed.
template <Allocator Memory>
const char *recipeJsonFailure(Memory &memory, std::string_view text) {
  std::string closing;
  bool in_string = false;
  bool escaped = false;
  for (const char byte : text) {
    if (in_string) {
      if (escaped) {
        escaped = false;
      } else if (byte == '\\') {
        escaped = true;
      } else if (byte == '"') {
        in_string = false;
      }
    } else if (byte == '"') {
      in_string = true;
    } else if (byte == '{' || byte == '[') {
      closing += byte == '{' ? '}' : ']';
    } else if (byte == '}' || byte == ']') {
      if (closing.empty() || closing.back() != byte) {
        return "SyntaxError";
      }

      closing.pop_back();
    }
  }

  std::reverse(closing.begin(), closing.end());
  constexpr std::array completions{"", "\"", "0", "null", ":null", "\":null", "\"\":null", "n\"", "0\"", "00\"", "000\"", "0000\"", "rue", "ue", "e", "alse", "lse", "se", "ull", "ll", "l"};
  for (const std::string_view suffix : completions) {
    if (suffix.empty() && closing.empty()) {
      continue;
    }

    std::string candidate{text};
    candidate += suffix;
    candidate += closing;
    try {
      const auto completed = JsonValue::parse(candidate);
      const char *diagnostic = "UnexpectedEndOfInput";
      if (completed.encoded().starts_with('{')) {
        completed.eachMember([&](JsonValue key, JsonValue value) {
          String<Memory> name{AllocatorRef<char, Memory>{memory}};
          key.string(name);
          const auto key_end = static_cast<std::size_t>(key.encoded().data() - candidate.data()) + key.encoded().size();
          if (key_end <= text.size() && name != "version" && name != "argv") {
            diagnostic = "UnknownField";
          }

          const auto token_started = static_cast<std::size_t>(value.encoded().data() - candidate.data()) < text.size();
          if (token_started && name == "argv") {
            if (!value.encoded().starts_with('[')) {
              diagnostic = "UnexpectedToken";
            } else {
              value.eachElement([&](JsonValue element) {
                const auto started = static_cast<std::size_t>(element.encoded().data() - candidate.data()) < text.size();
                if (started && !element.encoded().starts_with('"')) {
                  diagnostic = "UnexpectedToken";
                }
              });
            }
          }

          if (token_started && name == "version" && value.encoded().find_first_of("[{tfn") == 0) {
            diagnostic = "UnexpectedToken";
          }
        });
      }

      return diagnostic;
    } catch (const std::exception &) {
    }
  }

  return "SyntaxError";
}

template <Allocator Memory>
std::vector<std::string> recipeArguments(Memory &memory, std::string_view text) {
  auto recipe = [&] {
    try {
      return JsonNode<Memory>::parse(memory, text);
    } catch (const std::exception &error) {
      if (std::string_view{error.what()} == "Duplicate JSON field") {
        throw std::runtime_error{"DuplicateField"};
      }

      throw std::runtime_error{recipeJsonFailure(memory, text)};
    }
  }();
  if (recipe.kind() != JsonKind::object) {
    throw std::runtime_error{"UnexpectedToken"};
  }

  const auto *version = recipe.find("version");
  const auto *argv = recipe.find("argv");
  if (!version || !argv) {
    throw std::runtime_error{"MissingField"};
  }

  if (recipe.children().size() != 2) {
    throw std::runtime_error{"UnknownField"};
  }

  if ((version->kind() != JsonKind::literal && version->kind() != JsonKind::string) || argv->kind() != JsonKind::array || version->text() == "true" || version->text() == "false" || version->text() == "null") {
    throw std::runtime_error{"UnexpectedToken"};
  }

  double number = 0;
  const auto number_text = version->text();
  const auto parsed = std::from_chars(number_text.data(), number_text.data() + number_text.size(), number);
  if (parsed.ec != std::errc{} || parsed.ptr != number_text.data() + number_text.size() || !std::isfinite(number) || std::floor(number) != number) {
    throw std::runtime_error{"InvalidNumber"};
  }

  if (number < 0 || number > std::numeric_limits<std::uint8_t>::max()) {
    throw std::runtime_error{"Overflow"};
  }
  if (number != 1 || argv->children().empty() || argv->children().size() > ExecutionOptions::max_arguments) {
    throw std::runtime_error{"InvalidProjectRecipe"};
  }

  std::vector<std::string> result;
  result.reserve(argv->children().size());
  for (const auto &argument : argv->children()) {
    if (argument.kind() != JsonKind::string) {
      throw std::runtime_error{"UnexpectedToken"};
    }

    result.emplace_back(argument.text());
  }

  return result;
}

template <Allocator Memory>
std::optional<std::vector<std::string>> loadRecipe(Memory &memory, std::string_view cwd, bool authorized) {
  const auto path = std::string{cwd} + "/.telar/setup.json";
  FileDescriptor parent;
  FileDescriptor file;
  try {
    parent = file_transfer::openParent(path);
    file = file_transfer::openRegular(parent.get(), "setup.json");
  } catch (const std::runtime_error &error) {
    if (std::string_view{error.what()} == "FileNotFound") {
      return std::nullopt;
    }

    throw;
  }

  if (!authorized) {
    throw std::runtime_error{"ProjectSetupRequiresExplicitSetupFlag"};
  }

  struct stat inode{};
  if (::fstat(file.get(), &inode) != 0 || inode.st_size > static_cast<off_t>(max_recipe_bytes)) {
    throw std::runtime_error{"InvalidProjectRecipe"};
  }

  std::string text;
  text.reserve(static_cast<std::size_t>(inode.st_size));
  std::array<char, max_recipe_bytes> bytes;
  for (;;) {
    const auto count = ::read(file.get(), bytes.data(), bytes.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }

    if (count < 0) {
      throw std::runtime_error{file_transfer::fileError(errno)};
    }

    if (count == 0) {
      break;
    }

    if (text.size() + static_cast<std::size_t>(count) > max_recipe_bytes) {
      throw std::runtime_error{"StreamTooLong"};
    }

    text.append(bytes.data(), static_cast<std::size_t>(count));
  }

  return recipeArguments(memory, text);
}

template <Allocator Memory>
void awaitSetup(ControlSession<Memory> &session, ExecutionRequest request, ExecutionReply reply) {
  request.action = ExecutionAction::status;
  request.arguments = {};
  const auto started = std::chrono::steady_clock::now();
  for (;;) {
    if (request.stdout_offset != reply.stdout_offset || request.stderr_offset != reply.stderr_offset) {
      throw std::runtime_error{"SetupOutputRetentionExceeded"};
    }

    writeBytes(STDERR_FILENO, reply.stdout_bytes);
    writeBytes(STDERR_FILENO, reply.stderr_bytes);
    request.stdout_offset += reply.stdout_bytes.size();
    request.stderr_offset += reply.stderr_bytes.size();
    if (execution::finished(reply) && request.stdout_offset == reply.stdout_total && request.stderr_offset == reply.stderr_total) {
      if (reply.state != ExecutionState::exited || reply.exit_code != 0) {
        throw std::runtime_error{"ProjectSetupFailed"};
      }

      return;
    }

    if (std::chrono::steady_clock::now() - started >= wait_timeout) {
      throw std::runtime_error{"SetupWaitTimedOutExecutionContinues"};
    }

    std::this_thread::sleep_for(execution::poll_interval);
    reply = execution::exchange(session, request);
  }
}

// worktree create can use the same authorization gate and execution semantics.
template <Allocator Memory>
std::optional<std::uint64_t> prepare(Memory &memory, std::string_view cwd, bool authorized, bool detach, std::string_view socket) {
  const auto recipe = loadRecipe(memory, cwd, authorized);
  if (!recipe) {
    return std::nullopt;
  }

  ServerOptions server_options{};
  server_options.socket = socket;
  const RuntimePaths paths{memory, server_options, ProcessEnvironment{}};
  ensureRuntime(memory, paths);
  ControlSession session{memory, paths.socket.c_str()};
  session.receiveTimeout(30);
  std::array<std::string_view, ExecutionOptions::max_arguments> argv;
  for (std::size_t index = 0; index < recipe->size(); ++index) {
    argv[index] = (*recipe)[index];
  }

  const auto id = randomIdentity();
  ExecutionRequest request{.action = ExecutionAction::start, .execution_id = id, .cwd = cwd, .arguments = std::span{argv}.first(recipe->size())};
  writeText(std::format("telar project: setup execution {}; each explicit invocation repeats the recipe\n", id), STDERR_FILENO);
  const auto reply = execution::exchange(session, request);
  if (!detach) {
    awaitSetup(session, request, reply);
  }

  return id;
}

template <Allocator Memory>
int run(Memory &memory, const Options &options) {
  try {
    const auto id = prepare(memory, options.cwd, true, options.detach, {});
    writeText(std::format("{{\"execution_id\":{},\"environment\":{},\"ready\":{}}}\n", id ? std::to_string(*id) : "null", quoteJson(!id ? "not_declared" : options.detach ? "running"
                                                                                                                                                                          : "ready"),
                          jsonBoolean(id && !options.detach)));
    return 0;
  } catch (const std::exception &error) {
    writeText("telar project: " + std::string{error.what()} + "; inspect the execution output, supply missing tools/access on this destination, then explicitly retry project setup\n", STDERR_FILENO);
    return 1;
  }
}

}

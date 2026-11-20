module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.suggestions.engine;

import telar.tbc;
import std;
import telar.sys.posix;
import telar.base.text;
import telar.base.text.json;
import telar.platform.error;
import telar.platform.net;
import telar.platform.primitives;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    constexpr std::size_t input_capacity = std::size_t{128} * 1024;
    constexpr std::size_t read_bytes = std::size_t{16} * 1024;
    constexpr std::size_t prompt_capacity = std::size_t{9} * 1024;
    constexpr std::size_t maximum_suggestion_bytes = 1024;
    constexpr int poll_interval_ms = 20;
    constexpr std::string_view blanks = " \r\t";

    // The first `count` characters of text, or all of it: substr(0, count) without its throw.
    constexpr std::string_view textPrefix(std::string_view text, std::size_t count) noexcept {
      text.remove_suffix(text.size() - std::min(count, text.size()));
      return text;
    }

    // Text past its first `offset` characters, or nothing: substr(offset) without its throw.
    constexpr std::string_view textAfter(std::string_view text, std::size_t offset) noexcept {
      text.remove_prefix(std::min(offset, text.size()));
      return text;
    }

  }

  SuggestionEngine::SuggestionEngine(ConcurrentMemory& memory, SuggestionOptions options)
      : memory_(memory),
        options_(options),
        input_(memory, input_capacity),
        line_(memory),
        text_(memory),
        encoded_(memory) {
    line_.reserve(maximum_record);
    text_.reserve(maximum_record);
    encoded_.reserve(maximum_record);
    input_.reserve(input_capacity);
  }

  bool SuggestionEngine::available() const noexcept {
    return !options_.arguments.empty();
  }

  void SuggestionEngine::stop() noexcept {
    stopping_ = true;
  }

  void SuggestionEngine::idle() noexcept {
    if (process_ && Clock::now() - last_used_ >= options_.idle_timeout) {
      process_.reset();
    }
  }

  void SuggestionEngine::suggest(const SuggestCommand& request, std::string_view prompt, EncodedReply<ConcurrentMemory>& reply) {
    TELAR_TRACE("suggestions.ask");
    if (!available()) {
      reply.send(CommandSuggestion{.request_id = request.request_id, .status = SuggestionStatus::unavailable});
      return;
    }

    SuggestionStatus status = SuggestionStatus::failed;
    std::string_view suggestion;

    try {
      ask(prompt);
      suggestion = answer();
      status = SuggestionStatus::ready;
      last_used_ = Clock::now();
    } catch (const Timeout&) {
      status = SuggestionStatus::timeout;
      process_.reset();
    } catch (const SystemError& error) {
      status = error.code() == ENOENT ? SuggestionStatus::unavailable : SuggestionStatus::failed;
      process_.reset();
    } catch (...) {
      process_.reset();
    }

    reply.send(CommandSuggestion{.request_id = request.request_id, .status = status, .text = status == SuggestionStatus::ready ? suggestion : std::string_view{}});
  }

  void SuggestionEngine::ask(std::string_view prompt) {
    idle();
    if (!process_) {
      Command command{memory_, Launch{.cwd = "/", .arguments = options_.arguments}, CommandPurpose::administration};

      process_.emplace(command.specification({}));
      input_.clear();
    }

    deadline_ = Clock::now() + options_.timeout;
    encoded_.assign(R"({"type":"prompt","message":)");
    appendJsonText(encoded_, prompt);
    encoded_.append("}\n");
    write(encoded_);
    bool settled = false;

    while (!settled) {
      nextLine();
      try {
        settled = settles(line_);
      } catch (const JsonError&) { // NOLINT(bugprone-empty-catch): a line that is not JSON is skipped, as the agent's records are read past it
      }
    }
  }

  bool SuggestionEngine::settles(std::string_view line) {
    const auto record = JsonValue::parse(line);
    const auto type = record.field("type");
    if (!type) {
      return false;
    }

    if (type->equals("response")) {
      const auto command = record.field("command");
      const auto success = record.field("success");
      if (command && command->equals("prompt") && (!success || !success->boolean())) {
        throw Rejected{};
      }
    }

    return type->equals("agent_settled");
  }

  std::string_view SuggestionEngine::answer() {
    write("{\"type\":\"get_last_assistant_text\"}\n");
    for (;;) {
      nextLine();
      const auto record = JsonValue::parse(line_);
      const auto type = record.field("type");
      const auto command = record.field("command");
      const auto success = record.field("success");
      if (!type || !type->equals("response") || !command || !command->equals("get_last_assistant_text") || !success || !success->boolean()) {
        continue;
      }

      const auto data = record.field("data");
      const auto text = data ? data->field("text") : ds::none;
      if (!text) {
        throw Rejected{};
      }

      text->string(text_);
      const auto suggestion = extract(text_);
      if (suggestion.empty()) {
        throw Rejected{};
      }

      Text16<maximum_suggestion_bytes>::validate(suggestion);
      return suggestion;
    }
  }

  std::string_view SuggestionEngine::extract(std::string_view text) noexcept {
    while (!text.empty()) {
      const auto newline = text.find('\n');
      auto line = trimText(textPrefix(text, newline), blanks);

      text = newline == std::string_view::npos ? std::string_view{} : textAfter(text, newline + 1);
      if (line.empty() || line.starts_with("```")) {
        continue;
      }

      if (line.size() >= 2 && line.starts_with('`') && line.ends_with('`')) {
        line = trimText(textPrefix(textAfter(line, 1), line.size() - 2), blanks);
      }

      if (line.empty()) {
        continue;
      }

      constexpr unsigned char space = 0x20;
      const bool controls = std::ranges::any_of(line, [](unsigned char byte) {
        return byte < space;
      });

      return line.size() > maximum_suggestion_bytes || controls ? std::string_view{} : line;
    }

    return {};
  }

  void SuggestionEngine::poll(bool writing) {
    if (stopping_) {
      throw Rejected{};
    }

    if (Clock::now() >= deadline_) {
      throw Timeout{};
    }

    ds::Array<pollfd, 3> descriptors{{{.fd = process_->output(), .events = POLLIN, .revents = 0}, {.fd = process_->error(), .events = POLLIN, .revents = 0}, {.fd = writing ? process_->input() : -1, .events = POLLOUT, .revents = 0}}};
    if (::poll(descriptors.dataMut(), descriptors.size(), poll_interval_ms) < 0 && sys::lastError() != EINTR) {
      throw SystemError{"Poll suggestion engine"};
    }

    ds::Array<Byte, read_bytes> bytes; // NOLINT(cppcoreguidelines-pro-type-member-init): read writes the bytes it counts before they are appended

    for (unsigned index = 0; index < 2; ++index) {
      if (descriptors[index].fd < 0 || descriptors[index].revents == 0) {
        continue;
      }

      const auto count = ::read(descriptors[index].fd, bytes.dataMut(), bytes.size());
      if (count > 0) {
        if (index == 0) {
          input_.append(std::span{bytes}.first(static_cast<std::size_t>(count)));
        }
      } else if (count == 0) {
        if (index == 0) {
          throw Rejected{};
        }

        process_.getMut().closeError();
      } else if (!socketWouldBlock(sys::lastError())) {
        throw SystemError{"Read suggestion engine"};
      }
    }
  }

  void SuggestionEngine::write(std::string_view bytes) {
    while (!bytes.empty()) {
      if (stopping_) {
        throw Rejected{};
      }

      if (Clock::now() >= deadline_) {
        throw Timeout{};
      }

      const auto count = ::write(process_->input(), bytes.data(), bytes.size());
      if (count > 0) {
        bytes.remove_prefix(static_cast<std::size_t>(count));
      } else if (count < 0 && socketWouldBlock(sys::lastError())) {
        poll(true);
      } else {
        throw Rejected{};
      }
    }
  }

  void SuggestionEngine::nextLine() {
    bool discarded = false;

    for (;;) {
      const auto bytes = input_.readable();
      const auto newline = std::ranges::find(bytes, '\n');
      if (newline != bytes.end()) {
        const auto length = static_cast<std::size_t>(newline - bytes.begin());
        if (!discarded && length <= maximum_record) {
          line_.assign(textView(bytes.first(length)));
          input_.consume(length + 1);
          return;
        }

        input_.consume(length + 1);
        discarded = false;
        continue;
      }

      if (bytes.size() > maximum_record || discarded) {
        input_.clear();
        discarded = true;
      }

      poll(false);
    }
  }

  tbc::val_a<ds::String<ConcurrentMemory>> suggestionPrompt(tbc::mut_a<ConcurrentMemory> memory, std::string_view cwd, std::string_view screen, std::string_view request) {
    ds::String<ConcurrentMemory> prompt{memory};

    prompt.reserve(prompt_capacity);
    prompt.assign("You are a shell assistant inside a terminal multiplexer. Reply with exactly one shell command line that fulfils the request, and nothing else: no markdown, no code fences, no quotes around the command, no explanation. If one command cannot fulfil the request, reply with one line starting with '#' that says why.\nWorking directory: ");
    prompt.append(cwd);
    prompt.append("\nLast screen rows:\n");
    prompt.append(screen);
    prompt.append("\nRequest: ");
    prompt.append(request);
    prompt.push('\n');
    return prompt;
  }

}

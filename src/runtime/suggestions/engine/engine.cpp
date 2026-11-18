module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.suggestions.engine;

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

  SuggestionEngine::SuggestionEngine(ConcurrentMemory& memory, SuggestionOptions options)
      : memory_(memory),
        options_(options),
        input_(memory, 128 * 1024),
        line_(AllocatorRef<char, ConcurrentMemory>{memory}),
        text_(AllocatorRef<char, ConcurrentMemory>{memory}),
        encoded_(AllocatorRef<char, ConcurrentMemory>{memory}) {
    line_.reserve(maximum_record);
    text_.reserve(maximum_record);
    encoded_.reserve(maximum_record);
    input_.reserve(128 * 1024);
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
      reply.send(CommandSuggestion{request.request_id, SuggestionStatus::unavailable});
      return;
    }

    SuggestionStatus status = SuggestionStatus::failed;
    std::string_view suggestion;

    try {
      idle();
      if (!process_) {
        Command command{memory_, Launch{.cwd = "/", .arguments = options_.arguments}, CommandPurpose::administration};

        process_.emplace(command.specification({}));
        input_.clear();
      }

      deadline_ = Clock::now() + options_.timeout;
      encoded_ = "{\"type\":\"prompt\",\"message\":";
      appendJsonText(encoded_, prompt);
      encoded_ += "}\n";
      write(encoded_);
      bool settled = false;

      while (!settled) {
        nextLine();
        try {
          const auto record = JsonValue::parse(line_);
          const auto type = record.field("type");
          if (!type) {
            continue;
          }

          settled = type->equals("agent_settled");
          if (type->equals("response")) {
            const auto command = record.field("command");
            const auto success = record.field("success");
            if (command && command->equals("prompt") && (!success || !success->boolean())) {
              throw Rejected{};
            }
          }
        } catch (const JsonError&) {
        }
      }

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
        suggestion = extract(text_);
        if (suggestion.empty()) {
          throw Rejected{};
        }

        Text16<1024>::validate(suggestion);
        status = SuggestionStatus::ready;
        last_used_ = Clock::now();
        break;
      }
    } catch (const Timeout&) {
      status = SuggestionStatus::timeout;
      process_.reset();
    } catch (const SystemError& error) {
      status = error.code() == ENOENT ? SuggestionStatus::unavailable : SuggestionStatus::failed;
      process_.reset();
    } catch (...) {
      process_.reset();
    }

    reply.send(CommandSuggestion{request.request_id, status, status == SuggestionStatus::ready ? suggestion : std::string_view{}});
  }

  std::string_view SuggestionEngine::extract(std::string_view text) noexcept {
    while (!text.empty()) {
      const auto newline = text.find('\n');
      auto line = trimText(text.substr(0, newline), " \r\t");

      text = newline == std::string_view::npos ? std::string_view{} : text.substr(newline + 1);
      if (line.empty() || line.starts_with("```")) {
        continue;
      }

      if (line.size() >= 2 && line.starts_with('`') && line.ends_with('`')) {
        line = trimText(line.substr(1, line.size() - 2), " \r\t");
      }

      if (line.empty()) {
        continue;
      }

      if (line.size() > 1024 || std::ranges::any_of(line, [](unsigned char byte) {
            return byte < 0x20;
          })) {
        return {};
      }

      return line;
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

    ds::Array<pollfd, 3> descriptors{{{process_->output(), POLLIN, 0}, {process_->error(), POLLIN, 0}, {writing ? process_->input() : -1, POLLOUT, 0}}};
    if (::poll(descriptors.dataMut(), descriptors.size(), 20) < 0 && sys::lastError() != EINTR) {
      throw SystemError{"Poll suggestion engine"};
    }

    ds::Array<Byte, 16 * 1024> bytes;

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
      const auto newline = std::find(bytes.begin(), bytes.end(), '\n');
      if (newline != bytes.end()) {
        const auto length = static_cast<std::size_t>(newline - bytes.begin());
        if (!discarded && length <= maximum_record) {
          line_.assign(reinterpret_cast<const char*>(bytes.data()), length);
          input_.consume(length + 1);
          return;
        }

        input_.consume(length + 1);
        discarded = false;
        continue;
      } else if (bytes.size() > maximum_record || discarded) {
        input_.clear();
        discarded = true;
      }

      poll(false);
    }
  }

  String<ConcurrentMemory> suggestionPrompt(ConcurrentMemory& memory, std::string_view cwd, std::string_view screen, std::string_view request) {
    String<ConcurrentMemory> prompt{AllocatorRef<char, ConcurrentMemory>{memory}};

    prompt.reserve(9 * 1024);
    prompt = "You are a shell assistant inside a terminal multiplexer. Reply with exactly one shell command line that fulfils the request, and nothing else: no markdown, no code fences, no quotes around the command, no explanation. If one command cannot fulfil the request, reply with one line starting with '#' that says why.\nWorking directory: ";
    prompt += cwd;
    prompt += "\nLast screen rows:\n";
    prompt += screen;
    prompt += "\nRequest: ";
    prompt += request;
    prompt += '\n';
    return prompt;
  }

}

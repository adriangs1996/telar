#pragma once

#include "../json_text.hpp"
#include <array>
#include <cstdio>
#include <string>
#include <vector>

namespace telar::runtime::cli::machine {

enum class Step {
  ssh,
  platform,
  telar,
  runtime,
  profile,
  agents,
  integrations,
  configuration,
  logins,
  check,
  count
};
enum class Status {
  ok,
  changed,
  skipped,
  failed,
  pending
};

struct SetupReport {
  static constexpr std::size_t max_text_bytes = 512;
  static constexpr std::size_t max_notes = 96;
  static constexpr auto titles = std::to_array<const char *>({"SSH access", "Platform", "telar", "Runtime", "Profile", "Agents", "Integrations", "Configuration", "Logins", "Check"});
  static constexpr auto steps = std::to_array<const char *>({"ssh", "platform", "telar", "runtime", "profile", "agents", "integrations", "configuration", "logins", "check"});
  static constexpr auto statuses = std::to_array<const char *>({"ok", "changed", "skipped", "failed", "pending"});

  struct Result {
    std::optional<Status> status;
    std::string detail;
    std::vector<std::string> notes;
  };

  bool json;
  std::array<Result, static_cast<std::size_t>(Step::count)> results;
  std::size_t note_count = 0;
  std::size_t omitted_notes = 0;

  static std::string bounded(std::string text) {
    text.resize(std::min(text.size(), max_text_bytes));
    for (auto &byte : text) {
      if ((static_cast<unsigned char>(byte) < 0x20 && byte != '\t') || byte == 0x7f) {
        byte = ' ';
      }
    }

    const auto begin = text.find_first_not_of(' ');
    return begin == std::string::npos ? std::string{} : text.substr(begin, text.find_last_not_of(' ') + 1 - begin);
  }

  void end(Step step, Status status, std::string detail) {
    const auto index = static_cast<std::size_t>(step);
    auto &result = results.at(index);
    result.status = status;
    result.detail = bounded(std::move(detail));
    if (!json) {
      std::printf("%2zu. %-14s %-10s %s\n", index + 1, titles[index], statuses[static_cast<std::size_t>(status)], result.detail.c_str());
      for (const auto &note : result.notes) {
        std::printf("      %s\n", note.c_str());
      }

      std::fflush(stdout);
    }
  }

  void note(Step step, std::string detail) {
    if (note_count == max_notes) {
      ++omitted_notes;
      return;
    }

    ++note_count;
    auto &result = results.at(static_cast<std::size_t>(step));
    result.notes.push_back(bounded(std::move(detail)));
    if (!json && result.status) {
      std::printf("      %s\n", result.notes.back().c_str());
      std::fflush(stdout);
    }
  }

  void progress(const std::string &text) const {
    if (!json) {
      std::printf("    ... %s\n", bounded(text).c_str());
      std::fflush(stdout);
    }
  }

  bool has(Status status) const {
    return std::ranges::any_of(results, [&](const Result &result) { return result.status == status; });
  }

  template <Allocator Memory>
  int refuse(Memory &memory, const std::string &label, const std::string &destination, std::string_view reason) const {
    if (!json) {
      std::printf("telar machine setup %s: %.*s.\n", label.c_str(), static_cast<int>(reason.size()), reason.data());
    } else {
      String<Memory> output{AllocatorRef<char, Memory>{memory}};
      output += "{\"label\":";
      appendJsonText(output, label, JsonEscapes::control);
      output += ",\"destination\":";
      appendJsonText(output, destination, JsonEscapes::control);
      output += ",\"ready\":false,\"pending\":false,\"changed\":false,\"refused\":";
      appendJsonText(output, reason, JsonEscapes::control);
      output += ",\"steps\":[]}\n";
      std::fwrite(output.data(), 1, output.size(), stdout);
    }

    return 1;
  }

  template <Allocator Memory>
  int finish(Memory &memory, const std::string &label, const std::string &destination) const {
    const bool failed = has(Status::failed);
    const bool pending = has(Status::pending);
    const bool changed = has(Status::changed);
    if (!json) {
      const auto *verdict = failed ? "is not ready; see the failed steps above" : pending ? "takes windows, but a login waits for you there; see Logins above and run setup again once it is done"
                                                                              : changed   ? "is ready"
                                                                                          : "was already set up; nothing changed";
      std::printf("%s %s.\n", label.c_str(), verdict);
      return failed ? 1 : 0;
    }

    String<Memory> output{AllocatorRef<char, Memory>{memory}};
    output += "{\"label\":";
    appendJsonText(output, label, JsonEscapes::control);
    output += ",\"destination\":";
    appendJsonText(output, destination, JsonEscapes::control);
    output += ",\"ready\":";
    output += !failed && !pending ? "true" : "false";
    output += ",\"pending\":";
    output += pending ? "true" : "false";
    output += ",\"changed\":";
    output += changed ? "true" : "false";
    if (omitted_notes != 0) {
      output += ",\"omitted_notes\":";
      output += std::to_string(omitted_notes);
    }

    output += ",\"steps\":[";
    bool first = true;
    for (std::size_t index = 0; index < results.size(); ++index) {
      const auto &result = results[index];
      if (!result.status) {
        continue;
      }

      if (!first) {
        output += ',';
      }

      first = false;
      output += "{\"step\":\"";
      output += steps[index];
      output += "\",\"status\":\"";
      output += statuses[static_cast<std::size_t>(*result.status)];
      output += "\",\"detail\":";
      appendJsonText(output, result.detail, JsonEscapes::control);
      output += ",\"notes\":[";
      bool first_note = true;
      for (const auto &note : result.notes) {
        if (!first_note) {
          output += ',';
        }

        first_note = false;
        appendJsonText(output, note, JsonEscapes::control);
      }

      output += "]}";
    }

    output += "]}\n";
    std::fwrite(output.data(), 1, output.size(), stdout);
    return failed ? 1 : 0;
  }
};

}

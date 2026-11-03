#pragma once

#include "payload.hpp"
#include "text.hpp"

namespace telar::runtime::cli::hooks {

template <Allocator Memory>
void toolEvent(FixedText<96> &output, Payload<Memory> &input) {
  const auto name = input.fields.text("tool_name");
  if (name.empty()) {
    output.assign({});
    return;
  }

  std::array<char, 192> buffer;
  std::size_t length = 0;
  const auto append = [&](std::string_view text) {
    const auto count = std::min(text.size(), buffer.size() - length);
    std::memcpy(buffer.data() + length, text.data(), count);
    length += count;
  };
  append("» ");
  append(name);
  for (const auto key : {"command", "cmd", "file_path", "filePath", "filepath", "path", "pattern", "url", "query", "prompt", "description"}) {
    if (const auto argument = input.tools.stringField(key); argument && !argument->empty()) {
      append(" ");
      append(*argument);
      break;
    }
  }

  eventLine(output, {buffer.data(), length});
}

template <Allocator Memory>
bool questionEvent(FixedText<96> &output, Payload<Memory> &input) {
  const auto questions = input.tools.value("questions");
  if (!questions || !questions->encoded().starts_with('[')) {
    return false;
  }

  bool first = true;
  bool found = false;
  questions->eachElement([&](JsonValue value) {
    if (!std::exchange(first, false) || !value.encoded().starts_with('{')) {
      return;
    }

    Object question{input.memory, value};
    if (const auto text = question.stringField("question"); text && !text->empty()) {
      eventLine(output, *text);
      found = true;
    }
  });

  return found;
}

inline void backgroundEvent(FixedText<96> &output, std::size_t count) {
  std::array<char, 96> buffer;
  const auto length = std::snprintf(buffer.data(), buffer.size(), "waiting for %zu background %s", count, count == 1 ? "agent" : "agents");
  output.assign({buffer.data(), static_cast<std::size_t>(length)});
}

}

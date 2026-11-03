#pragma once

#include "telar_base/memory/allocator.hpp"

namespace telar::runtime {

template <Allocator Memory>
String<Memory> suggestionPrompt(Memory &memory, std::string_view cwd, std::string_view screen, std::string_view request) {
  String<Memory> prompt{AllocatorRef<char, Memory>{memory}};
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

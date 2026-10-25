#pragma once

#include "../memory/fixed_text.hpp"
#include "provider.hpp"

namespace telar::runtime {

struct AgentResume {
  AgentProvider provider = AgentProvider::unknown;
  FixedText<64> session{};
  FixedText<96> title{};
  AgentTitleSource title_source = AgentTitleSource::telar;
  bool in_pane = false;
};

inline bool hexadecimal(char value) noexcept {
  return (value >= '0' && value <= '9') || (value >= 'a' && value <= 'f') || (value >= 'A' && value <= 'F');
}

inline bool validResumeSession(AgentProvider provider, std::string_view value) noexcept {
  if (provider == AgentProvider::opencode) {
    if (value.size() != 30 || !value.starts_with("ses_")) {
      return false;
    }

    for (std::size_t index = 4; index < value.size(); ++index) {
      const auto character = value[index];
      const bool valid = index < 16 ? hexadecimal(character) : (character >= '0' && character <= '9') || (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z');
      if (!valid) {
        return false;
      }
    }

    return true;
  }

  if (describeProvider(provider).name.empty() || value.size() != 36) {
    return false;
  }

  for (std::size_t index = 0; index < value.size(); ++index) {
    const bool separator = index == 8 || index == 13 || index == 18 || index == 23;
    if (separator ? value[index] != '-' : !hexadecimal(value[index])) {
      return false;
    }
  }

  return true;
}

inline std::span<const std::string_view> resumeArguments(const AgentResume &resume, std::array<std::string_view, 4> &arguments) noexcept {
  if (!validResumeSession(resume.provider, resume.session.view())) {
    return {};
  }

  arguments[0] = resume.provider == AgentProvider::cursor ? "cursor-agent" : describeProvider(resume.provider).name;
  arguments[1] = resume.provider == AgentProvider::codex ? "resume" : resume.provider == AgentProvider::pi || resume.provider == AgentProvider::opencode ? "--session"
                                                                                                                                                         : "--resume";
  std::size_t count = 2;
  if (resume.provider == AgentProvider::codex && resume.in_pane) {
    arguments[count++] = "--no-daemon";
  }
  arguments[count++] = resume.session.view();

  return std::span{arguments}.first(count);
}

}

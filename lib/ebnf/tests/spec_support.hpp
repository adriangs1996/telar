#pragma once

// Helpers for the tests of the shipped specs: each group of specs has its own test file
// under tests/specs, written with these.
#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include <gtest/gtest.h>

import telar.ebnf.matcher;

namespace spec_support {

using words = std::vector<std::string_view>;

inline auto readSpec(std::string_view name) -> std::string {
  auto file = std::ifstream{std::string{EBNF_SPECS_DIR} + "/" + std::string{name} + ".ebnf", std::ios::binary};
  if (!file) {
    throw std::runtime_error("Missing spec " + std::string{name});
  }
  return {std::istreambuf_iterator<char>{file}, std::istreambuf_iterator<char>{}};
}

// Each spec compiled once for the whole test run.
inline auto spec(std::string_view name) -> const ebnf::command_spec & {
  static std::map<std::string, std::unique_ptr<ebnf::command_spec>, std::less<>> compiled;
  auto found = compiled.find(name);
  if (found == compiled.end()) {
    found = compiled.emplace(std::string{name}, std::make_unique<ebnf::command_spec>(ebnf::command_spec::compile(readSpec(name)))).first;
  }
  return *found->second;
}

class SpecTest : public testing::Test {
protected:
  std::unique_ptr<ebnf::match_scratch> scratch_ = std::make_unique<ebnf::match_scratch>();
  std::array<ebnf::candidate, 512> out_{};

  // What Tab offers after `line` for the `partial` word: literals as their text, providers
  // as @name.
  auto texts(std::string_view name, const words &line, std::string_view partial) -> std::vector<std::string> {
    const auto result = spec(name).complete(line, partial, *scratch_, out_);
    EXPECT_EQ(result.status, ebnf::match_status::valid);
    std::vector<std::string> shown;
    for (std::size_t index = 0; index < result.count; ++index) {
      const auto &candidate = out_[index];
      shown.push_back((candidate.kind == ebnf::candidate_kind::provider ? "@" : "") + std::string{candidate.prefix} + std::string{candidate.text});
    }
    return shown;
  }

  // The description Tab shows for `text` after `line`, or empty.
  auto description(std::string_view name, const words &line, std::string_view text) -> std::string {
    const auto result = spec(name).complete(line, text, *scratch_, out_);
    for (std::size_t index = 0; index < result.count; ++index) {
      if (out_[index].text == text) {
        return std::string{out_[index].description};
      }
    }
    return {};
  }

  // The first word the spec rejects in `line`, or -1 when it accepts the line.
  auto firstInvalid(std::string_view name, const words &line) -> std::int64_t {
    const auto result = spec(name).check(line, *scratch_);
    EXPECT_NE(result.status, ebnf::match_status::unknown);
    return result.status == ebnf::match_status::invalid ? std::int64_t{result.word} : -1;
  }

  static auto contains(const std::vector<std::string> &shown, std::string_view expected) -> bool {
    return std::ranges::find(shown, expected) != shown.end();
  }
};

}

#include "terminal/control/parser.hpp"
#include <cstdio>
#include <cstdlib>
#include <random>

using namespace telar::runtime;
using namespace telar::runtime::control;

namespace {
void require(bool condition) {
  if (!condition) {
    std::abort();
  }
}

std::span<const std::uint8_t> bytes(std::string_view text) {
  return {reinterpret_cast<const std::uint8_t *>(text.data()), text.size()};
}

struct Consumer {
  std::vector<std::string> events;
  bool accept = true;

  void ordinary(std::span<const std::uint8_t> input) {
    const std::string_view value{reinterpret_cast<const char *>(input.data()), input.size()};
    if (!events.empty() && events.back().starts_with("text:")) {
      events.back().append(value);
    } else {
      events.push_back("text:" + std::string{value});
    }
  }

  bool enquire() {
    if (!accept) {
      return false;
    }

    events.emplace_back("enquiry");
    return true;
  }

  bool streamable(Sequence) {
    return false;
  }

  bool borrowableApc(Sequence header) const noexcept {
    return header.body().starts_with("Ga=q");
  }

  bool complete(Sequence sequence) {
    if (!accept) {
      return false;
    }

    events.push_back(std::to_string(static_cast<unsigned>(sequence.kind)) + ":" + std::string{sequence.body()} + ":" + std::to_string(static_cast<unsigned>(sequence.ending)));
    return true;
  }
};

void partitions(std::string_view input, const std::vector<std::string> &expected) {
  SystemAllocator memory;
  for (std::size_t split = 0; split <= input.size(); ++split) {
    Parser parser{memory};
    Consumer consumer;
    require(parser.feed(bytes(input.substr(0, split)), consumer) == split);
    require(parser.feed(bytes(input.substr(split)), consumer) == input.size() - split);
    require(consumer.events == expected);
  }

  Parser parser{memory};
  Consumer consumer;
  for (const auto &byte : input) {
    require(parser.feed(bytes({&byte, 1}), consumer) == 1);
  }
  require(consumer.events == expected);
}

void oversizedRecovery() {
  SystemAllocator upstream;
  BudgetAllocator memory{upstream, 8 * 1024 * 1024};
  {
    Parser parser{memory};
    Consumer consumer;
    std::string request{"\x1bP+q"};
    request.append(Parser<decltype(memory)>::dcs_limit, 'A');
    require(parser.feed(bytes(request), consumer) == request.size());
    require(parser.overLimit() == 1 && consumer.events.empty());
    require(parser.feed(bytes("\x1b[6n"), consumer) == 4);
    require(consumer.events == std::vector<std::string>{"1:6n:0"});
  }
  require(memory.liveBytes() == 0);
}

void backpressure() {
  SystemAllocator memory;
  Parser parser{memory};
  Consumer consumer;
  consumer.accept = false;
  const std::string query = "\x1b[6nremaining";
  require(parser.feed(bytes(query), consumer) == 4);
  require(parser.blocked());
  require(parser.feed(bytes("unconsumed"), consumer) == 0);
  require(consumer.events.empty());
  consumer.accept = true;
  require(parser.feed({}, consumer) == 0);
  require(!parser.blocked());
  require(consumer.events == std::vector<std::string>{"1:6n:0"});
  require(parser.feed(bytes("remaining"), consumer) == 9);
  require(consumer.events.back() == "text:remaining");
}

void apcOwnedRuns() {
  SystemAllocator memory;
  for (unsigned byte = 0; byte <= UINT8_MAX; ++byte) {
    std::string input{"\x1b_Ga=q,i=9;"};
    input.append(260, 'A');
    input.push_back(static_cast<char>(byte));
    input.append(32, 'B');
    input.append("\x1b\\\x1b[5n");
    Parser scalar{memory};
    Consumer expected;
    for (const auto &character : input) {
      require(scalar.feed(bytes({&character, 1}), expected) == 1);
    }
    partitions(input, expected.events);
  }

  for (const auto length : {255u, 256u, 257u, 511u, 512u, 513u}) {
    std::string input{"\x1b_G"};
    input.append(length - input.size(), 'A');
    input.append("\x1b\\");
    const auto body = input.substr(2, length - 2);
    partitions(input, {"4:" + body + ":1", "0:\\:0"});
  }

  Parser parser{memory};
  Consumer consumer;
  consumer.accept = false;
  std::string input{"\x1b_Ga=q;"};
  input.append(4096, 'A');
  const auto expected = "4:" + input.substr(2) + ":1";
  input.append("\x1b\\unconsumed");
  const auto consumed = parser.feed(bytes(input), consumer);
  require(consumed == input.size() - 11 && parser.blocked());
  input.assign(input.size(), 'z');
  consumer.accept = true;
  require(parser.feed({}, consumer) == 0);
  require(consumer.events == std::vector<std::string>{expected});
  require(!parser.blocked());
}

struct StreamingConsumer : Consumer {
  unsigned hooks = 0;
  bool streamable(Sequence sequence) {
    ++hooks;
    require(sequence.body().ends_with(';'));
    return true;
  }
};

void apcLateStreaming() {
  SystemAllocator memory;
  for (const auto length : {254u, 255u, 256u, 257u, 512u}) {
    Parser parser{memory};
    StreamingConsumer consumer;
    std::string input{"\x1b_G"};
    input.append(length - input.size(), 'A');
    input.append(";payload;still-streaming\x1b\\");
    require(parser.feed(bytes(input), consumer) == input.size());
    require(consumer.hooks == 1);
    require(consumer.events.size() == 2 && consumer.events.front() == "text:" + input);
    require(consumer.events.back() == "0:\\:0");
  }
}

struct SizeConsumer {
  std::size_t body_size = 0;
  unsigned completions = 0;
  void ordinary(std::span<const std::uint8_t>) {}
  bool enquire() { return true; }
  bool streamable(Sequence) { return false; }
  bool complete(Sequence sequence) {
    if (sequence.kind == Kind::apc) {
      ++completions;
      body_size = sequence.body().size();
      require(sequence.body().front() == 'G');
      require(sequence.body().find_first_not_of('A', 1) == std::string_view::npos);
    }
    return true;
  }
};

void apcLimitAndAllocation() {
  SystemAllocator upstream;
  BudgetAllocator memory{upstream, 2 * Parser<SystemAllocator>::apc_limit};
  constexpr auto limit = Parser<SystemAllocator>::apc_limit;
  std::string input{"\x1b_G"};
  input.append(limit - input.size(), 'A');
  for (const auto &extra : {std::string{}, std::string{"\x98\xa0\xff", 3}, std::string{"A"}}) {
    Parser parser{memory};
    SizeConsumer consumer;
    require(parser.feed(bytes(input), consumer) == input.size());
    require(parser.overLimit() == 0);
    require(parser.feed(bytes(extra), consumer) == extra.size());
    require(parser.feed(bytes("\x1b\\"), consumer) == 2);
    const bool oversized = extra == "A";
    require(parser.overLimit() == (oversized ? 1u : 0u));
    require(consumer.completions == (oversized ? 0u : 1u));
    require(oversized || consumer.body_size == limit - 2);
  }
  require(memory.liveBytes() == 0);

  BudgetAllocator denied{upstream, 0};
  Parser parser{denied};
  SizeConsumer consumer;
  bool failed = false;
  try {
    parser.feed(bytes(input).first(1024), consumer);
  } catch (const std::bad_alloc &) {
    failed = true;
  }
  require(failed && denied.failures() == 1);
  parser.discard();
  require(denied.liveBytes() == 0);
  require(parser.feed(bytes("\x1b[5n"), consumer) == 4 && parser.ground());
}

void borrowedApcMemory() {
  SystemAllocator upstream;
  BudgetAllocator memory{upstream, 0};
  std::string input{"\x1b_Ga=q;"};
  input.append(4096, 'A');
  input.append("\x1b\\");
  {
    Parser parser{memory};
    Consumer consumer;
    require(parser.feed(bytes(input), consumer) == input.size());
    require(consumer.events.size() == 2 && parser.ground());
    require(memory.allocations() == 0 && memory.failures() == 0);
  }
  {
    Parser parser{memory};
    Consumer consumer;
    consumer.accept = false;
    bool failed = false;
    try {
      parser.feed(bytes(input), consumer);
    } catch (const std::bad_alloc &) {
      failed = true;
    }
    require(failed && memory.failures() == 1);
    parser.discard();
    require(memory.liveBytes() == 0 && parser.ground());
  }

  for (const bool oversized : {false, true}) {
    constexpr auto limit = Parser<SystemAllocator>::apc_limit;
    std::string full{"\x1b_Ga=q;"};
    full.append(limit - full.size() + oversized, 'A');
    full.append("\x1b\\");
    BudgetAllocator bounded{upstream, limit * 2};
    Parser parser{bounded};
    Consumer consumer;
    // Consumer's event strings use the system heap; the parser's budget is
    // independent, allowing the zero-allocation borrowing path to be checked.
    require(parser.feed(bytes(full), consumer) == full.size());
    require(parser.ground() && parser.overLimit() == (oversized ? 1u : 0u));
    if (!oversized) {
      require(bounded.allocations() == 0 && consumer.events.size() == 2);
      require(consumer.events.front().size() == limit + 2);
    } else {
      require(consumer.events == std::vector<std::string>{"0:\\:0"});
    }
  }
}

void boundedFuzz() {
  SystemAllocator system;
  BudgetAllocator memory{system, 8 * 1024 * 1024};
  std::mt19937 random{0x435349};
  for (unsigned run = 0; run < 2000; ++run) {
    Parser parser{memory};
    Consumer consumer;
    std::string input;
    input.resize(random() % 2048);
    for (auto &byte : input) {
      byte = static_cast<char>(random());
    }

    std::size_t offset = 0;
    while (offset < input.size()) {
      const auto count = std::min<std::size_t>(1 + random() % 31, input.size() - offset);
      require(parser.feed(bytes(input).subspan(offset, count), consumer) == count);
      offset += count;
    }

    parser.feed(bytes("\x18\x1b[6n"), consumer);
    require(parser.ground());
    require(consumer.events.back() == "1:6n:0");
  }
  require(memory.liveBytes() == 0);
}
}

int main() {
  for (const auto control : {std::uint8_t{0x98}, std::uint8_t{0x9e}, std::uint8_t{0x9f}}) {
    const auto input = std::string{"\x1b_Ga=q,i=9;"} + static_cast<char>(control) + "AAAA\x1b\\";
    partitions(input, {"4:Ga=q,i=9;AAAA:1", "0:\\:0"});
  }

  partitions("A\x1b[6nB\x1b[?6n", {"text:A", "1:6n:0", "text:B", "1:?6n:0"});
  partitions("\x1bP$qm\x1b\\", {"2:$qm:1", "0:\\:0"});
  partitions("\x1b]4;1;?\a", {"3:4;1;?:2"});
  partitions("\x1b_25a1;s\x1b\\", {"4:25a1;s:1", "0:\\:0"});
  partitions("\x1b]52;c;?\x18ok", {"text:ok"});
  partitions("\x1b[\x05" "6n", {"enquiry", "1:6n:0"});
  partitions("\x1b[1;\x1b[6n", {"1:6n:0"});
  partitions("\x1bP$qm\x18", {"2:$qm:1"});
  partitions("\x1bP$q\x7f" "m\x1b\\", {"2:$qm:1", "0:\\:0"});
  partitions("\x1b_25a1;s\x1a", {"4:25a1;s:1"});
  partitions("\x1bP+\x9b" "5n", {"1:5n:0"});
  partitions("\x1bP\x9d" "10;?\x1b\\", {"3:10;?:1", "0:\\:0"});
  partitions("\x1b_\x9a", {"4::1", "0:Z:0"});
  borrowedApcMemory();
  apcOwnedRuns();
  apcLateStreaming();
  apcLimitAndAllocation();
  backpressure();
  boundedFuzz();
  oversizedRecovery();
  std::puts("Native control parser tests passed");
}

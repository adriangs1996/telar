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
  backpressure();
  boundedFuzz();
  oversizedRecovery();
  std::puts("Native control parser tests passed");
}

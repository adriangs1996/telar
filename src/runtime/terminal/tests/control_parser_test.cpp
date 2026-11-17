#include <cstdint>

import std;
import telar.base.memory.allocators;
import telar.runtime.terminal.control;
import telar.testing;

using telar::testing::check;

using namespace telar;
using namespace telar::runtime;
using namespace telar::runtime::control;

namespace {

  std::span<const std::uint8_t> bytes(std::string_view text) {
    return {reinterpret_cast<const std::uint8_t*>(text.data()), text.size()};
  }

  struct Consumer {
    std::vector<std::string> events;
    bool accept = true;

    void ordinary(std::span<const std::uint8_t> input) {
      const std::string_view value{reinterpret_cast<const char*>(input.data()), input.size()};

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

  void partitions(std::string_view input, const std::vector<std::string>& expected) {
    SystemAllocator memory;

    for (std::size_t split = 0; split <= input.size(); ++split) {
      Parser parser{memory};
      Consumer consumer;

      check(parser.feed(bytes(input.substr(0, split)), consumer) == split);
      check(parser.feed(bytes(input.substr(split)), consumer) == input.size() - split);
      check(consumer.events == expected);
    }

    Parser parser{memory};
    Consumer consumer;

    for (const auto& byte : input) {
      check(parser.feed(bytes({&byte, 1}), consumer) == 1);
    }

    check(consumer.events == expected);
  }

  void oversizedRecovery() {
    SystemAllocator upstream;
    BudgetAllocator memory{upstream, 8 * 1024 * 1024};

    {
      Parser parser{memory};
      Consumer consumer;
      std::string request{"\x1bP+q"};

      request.append(Parser<decltype(memory)>::dcs_limit, 'A');
      check(parser.feed(bytes(request), consumer) == request.size());
      check(parser.overLimit() == 1 && consumer.events.empty());
      check(parser.feed(bytes("\x1b[6n"), consumer) == 4);
      check(consumer.events == std::vector<std::string>{"1:6n:0"});
    }

    check(memory.liveBytes() == 0);
  }

  void parameterFallback() {
    struct Case {
      std::string_view body;
      std::size_t count;
      std::string_view modifiers;
      bool colon;
    };

    constexpr Case cases[]{
        {"?1234;5n", 2, "?", false},
        {"?1234:5n", 2, "?", true},
        {"?1234\x7f$n", 1, "?$", false},
    };

    for (const auto& item : cases) {
      const auto parsed = Parameters::parse(item.body);

      check(parsed.has_value());
      check(parsed->count == item.count && parsed->modifiers() == item.modifiers);
      check(parsed->colon == item.colon && parsed->final == 'n');
      check(parsed->values[0] == 1234);
      check(parsed->values[1] == (item.count == 2 ? 5 : 0));
      for (std::size_t index = 2; index < parsed->values.size(); ++index) {
        check(parsed->values[index] == 0);
      }
    }
  }

  void backpressure() {
    SystemAllocator memory;
    Parser parser{memory};
    Consumer consumer;

    consumer.accept = false;
    const std::string query = "\x1b[6nremaining";

    check(parser.feed(bytes(query), consumer) == 4);
    check(parser.blocked());
    check(parser.feed(bytes("unconsumed"), consumer) == 0);
    check(consumer.events.empty());
    consumer.accept = true;
    check(parser.feed({}, consumer) == 0);
    check(!parser.blocked());
    check(consumer.events == std::vector<std::string>{"1:6n:0"});
    check(parser.feed(bytes("remaining"), consumer) == 9);
    check(consumer.events.back() == "text:remaining");
  }

  void csiBurstBackpressure() {
    struct PausingConsumer : Consumer {
      bool pause = true;

      bool complete(Sequence sequence) {
        if (pause && events.size() == 2) {
          accept = false;
        }

        return Consumer::complete(sequence);
      }
    };

    SystemAllocator memory;
    Parser parser{memory};
    PausingConsumer consumer;
    std::string input = "\x1b[5n\x1b[6n\x1b[?6nremaining";

    check(parser.feed(bytes(input), consumer) == 13);
    check(parser.blocked());
    check(consumer.events == std::vector<std::string>{"1:5n:0", "1:6n:0"});
    input.assign(input.size(), 'z');
    consumer.pause = false;
    consumer.accept = true;
    check(parser.feed({}, consumer) == 0);
    check(!parser.blocked() && parser.ground());
    check(consumer.events.back() == "1:?6n:0");
    check(parser.feed(bytes("remaining\x1b[12;"), consumer) == 14);
    check(consumer.events.back() == "text:remaining");
    check(parser.feed(bytes("34H"), consumer) == 3);
    check(consumer.events.back() == "1:12;34H:0");

    BudgetAllocator denied{memory, 0};
    Parser retained{denied};
    PausingConsumer blocked;
    std::string long_query = "\x1b[5n\x1b[6n\x1b[";

    long_query.append(254, '0');
    long_query.append("5n");
    bool failed = false;

    try {
      retained.feed(bytes(long_query), blocked);
    } catch (const std::bad_alloc&) {
      failed = true;
    }

    check(failed && denied.failures() == 1);
    check(blocked.events == std::vector<std::string>{"1:5n:0", "1:6n:0"});
    retained.discard();
    check(retained.ground() && denied.liveBytes() == 0);
    blocked.pause = false;
    blocked.accept = true;
    check(retained.feed(bytes("\x1b[5n"), blocked) == 4);
    check(blocked.events.back() == "1:5n:0");
  }

  void stringHeaderClassificationOnce() {
    struct HeaderConsumer : Consumer {
      std::size_t classifications = 0;

      bool streamable(Sequence) {
        ++classifications;
        return false;
      }
    };

    SystemAllocator memory;
    Parser parser{memory};
    HeaderConsumer consumer;

    for (const auto* prefix : {"\x1b_Ga=q,i=9,s=1,v=1,X=", "\x1b]5522;type=read;", "\x1bP+q"}) {
      const auto request = std::string{prefix} + std::string(1024, 'x') + ';' + std::string(4096, ';') + "\x1b\\";
      const auto before = consumer.classifications;

      for (const auto& byte : request) {
        check(parser.feed(bytes({&byte, 1}), consumer) == 1);
      }

      check(consumer.classifications == before + 1);
      check(parser.ground());
    }

    parser.feed(bytes("\x1b_Ga=q;"), consumer);
    const auto before = consumer.classifications;

    parser.discard();
    parser.feed(bytes("\x1b_Ga=q;;\x1b\\"), consumer);
    check(consumer.classifications == before + 1);
    check(parser.ground());
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

      for (const auto& character : input) {
        check(scalar.feed(bytes({&character, 1}), expected) == 1);
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

    check(consumed == input.size() - 11 && parser.blocked());
    input.assign(input.size(), 'z');
    consumer.accept = true;
    check(parser.feed({}, consumer) == 0);
    check(consumer.events == std::vector<std::string>{expected});
    check(!parser.blocked());
  }

  struct StreamingConsumer : Consumer {
    unsigned hooks = 0;

    bool streamable(Sequence sequence) {
      ++hooks;
      check(sequence.body().ends_with(';'));
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
      check(parser.feed(bytes(input), consumer) == input.size());
      check(consumer.hooks == 1);
      check(consumer.events.size() == 2 && consumer.events.front() == "text:" + input);
      check(consumer.events.back() == "0:\\:0");
    }
  }

  struct SizeConsumer {
    std::size_t body_size = 0;
    unsigned completions = 0;

    void ordinary(std::span<const std::uint8_t>) {}

    bool enquire() {
      return true;
    }

    bool streamable(Sequence) {
      return false;
    }

    bool complete(Sequence sequence) {
      if (sequence.kind == Kind::apc) {
        ++completions;
        body_size = sequence.body().size();
        check(sequence.body().front() == 'G');
        check(sequence.body().find_first_not_of('A', 1) == std::string_view::npos);
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
    for (const auto& extra : {std::string{}, std::string{"\x98\xa0\xff", 3}, std::string{"A"}}) {
      Parser parser{memory};
      SizeConsumer consumer;

      check(parser.feed(bytes(input), consumer) == input.size());
      check(parser.overLimit() == 0);
      check(parser.feed(bytes(extra), consumer) == extra.size());
      check(parser.feed(bytes("\x1b\\"), consumer) == 2);
      const bool oversized = extra == "A";

      check(parser.overLimit() == (oversized ? 1u : 0u));
      check(consumer.completions == (oversized ? 0u : 1u));
      check(oversized || consumer.body_size == limit - 2);
    }

    check(memory.liveBytes() == 0);

    BudgetAllocator denied{upstream, 0};
    Parser parser{denied};
    SizeConsumer consumer;
    bool failed = false;

    try {
      parser.feed(bytes(input).first(1024), consumer);
    } catch (const std::bad_alloc&) {
      failed = true;
    }

    check(failed && denied.failures() == 1);
    parser.discard();
    check(denied.liveBytes() == 0);
    check(parser.feed(bytes("\x1b[5n"), consumer) == 4 && parser.ground());
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

      check(parser.feed(bytes(input), consumer) == input.size());
      check(consumer.events.size() == 2 && parser.ground());
      check(memory.allocations() == 0 && memory.failures() == 0);
    }

    {
      Parser parser{memory};
      Consumer consumer;

      consumer.accept = false;
      bool failed = false;

      try {
        parser.feed(bytes(input), consumer);
      } catch (const std::bad_alloc&) {
        failed = true;
      }

      check(failed && memory.failures() == 1);
      parser.discard();
      check(memory.liveBytes() == 0 && parser.ground());
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
      check(parser.feed(bytes(full), consumer) == full.size());
      check(parser.ground() && parser.overLimit() == (oversized ? 1u : 0u));
      if (!oversized) {
        check(bounded.allocations() == 0 && consumer.events.size() == 2);
        check(consumer.events.front().size() == limit + 2);
      } else {
        check(consumer.events == std::vector<std::string>{"0:\\:0"});
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
      for (auto& byte : input) {
        byte = static_cast<char>(random());
      }

      std::size_t offset = 0;

      while (offset < input.size()) {
        const auto count = std::min<std::size_t>(1 + random() % 31, input.size() - offset);

        check(parser.feed(bytes(input).subspan(offset, count), consumer) == count);
        offset += count;
      }

      parser.feed(bytes("\x18\x1b[6n"), consumer);
      check(parser.ground());
      check(consumer.events.back() == "1:6n:0");
    }

    check(memory.liveBytes() == 0);
  }
}

static void partitionTable() {
  for (const auto control : {std::uint8_t{0x98}, std::uint8_t{0x9e}, std::uint8_t{0x9f}}) {
    const auto input = std::string{"\x1b_Ga=q,i=9;"} + static_cast<char>(control) + "AAAA\x1b\\";

    partitions(input, {"4:Ga=q,i=9;AAAA:1", "0:\\:0"});
  }

  partitions("\x1b[5n\x1b[6n\x1b[?6ntext\x1b[12;", {"1:5n:0", "1:6n:0", "1:?6n:0", "text:text"});
  partitions("A\x1b[6nB\x1b[?6n", {"text:A", "1:6n:0", "text:B", "1:?6n:0"});
  partitions("\x1bP$qm\x1b\\", {"2:$qm:1", "0:\\:0"});
  partitions("\x1b]4;1;?\a", {"3:4;1;?:2"});
  partitions("\x1b_25a1;s\x1b\\", {"4:25a1;s:1", "0:\\:0"});
  partitions("\x1b]52;c;?\x18ok", {"text:ok"});
  partitions("\x1b[\x05"
             "6n",
      {"enquiry", "1:6n:0"});
  partitions("\x1b[1;\x1b[6n", {"1:6n:0"});
  partitions("\x1bP$qm\x18", {"2:$qm:1"});
  partitions("\x1bP$q\x7f"
             "m\x1b\\",
      {"2:$qm:1", "0:\\:0"});
  partitions("\x1b_25a1;s\x1a", {"4:25a1;s:1"});
  partitions("\x1bP+\x9b"
             "5n",
      {"1:5n:0"});
  partitions("\x1bP\x9d"
             "10;?\x1b\\",
      {"3:10;?:1", "0:\\:0"});
  partitions("\x1b_\x9a", {"4::1", "0:Z:0"});
}

static const telar::testing::Case case_partitions{"control_parser.partitions", partitionTable};
static const telar::testing::Case case_borrowed_apc_memory{"control_parser.borrowed_apc_memory", borrowedApcMemory};
static const telar::testing::Case case_apc_owned_runs{"control_parser.apc_owned_runs", apcOwnedRuns};
static const telar::testing::Case case_apc_late_streaming{"control_parser.apc_late_streaming", apcLateStreaming};
static const telar::testing::Case case_apc_limit_and_allocation{"control_parser.apc_limit_and_allocation", apcLimitAndAllocation};
static const telar::testing::Case case_backpressure{"control_parser.backpressure", backpressure};
static const telar::testing::Case case_csi_burst_backpressure{"control_parser.csi_burst_backpressure", csiBurstBackpressure};
static const telar::testing::Case case_string_header_classification_once{"control_parser.string_header_classification_once", stringHeaderClassificationOnce};
static const telar::testing::Case case_bounded_fuzz{"control_parser.bounded_fuzz", boundedFuzz};
static const telar::testing::Case case_oversized_recovery{"control_parser.oversized_recovery", oversizedRecovery};
static const telar::testing::Case case_parameter_fallback{"control_parser.parameter_fallback", parameterFallback};

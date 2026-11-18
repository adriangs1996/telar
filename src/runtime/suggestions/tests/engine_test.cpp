import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.platform.fs;
import telar.runtime.suggestions.engine;
import telar.runtime.transport.connection;
import telar.wire.editor;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // An engine speaking the RPC: it settles every prompt and answers `git status`, after the
  // records `before_answer` prints first.
  std::string answering(std::string_view before_answer = {}) {
    return std::format(R"(while IFS= read -r line; do case "$line" in *get_last_assistant_text*) {} printf '%s\n' '{{"type":"response","command":"get_last_assistant_text","success":true,"data":{{"text":"git status"}}}}';; *) printf '%s\n' '{{"type":"response","command":"prompt","success":true}}' '{{"type":"agent_settled"}}';; esac; done)", before_answer);
  }

  SuggestionStatus ask(SuggestionEngine& engine, ConcurrentMemory& memory, std::uint64_t request, std::string* text = nullptr) {
    EncodedReply reply{memory};
    ds::Array<Byte, 4096> scratch;
    DecodeStorage storage{scratch.viewMut()};

    engine.suggest(SuggestCommand{.request_id = request, .pane_id = 1}, "Prompt", reply);
    const auto suggestion = Codec::decode<CommandSuggestion>(reply.payload(), storage);

    check(suggestion.request_id == request);
    if (text != nullptr) {
      *text = suggestion.text;
    }

    return suggestion.status;
  }

  // An engine that refuses the prompt, or one that exits, fails that request at once; the next
  // one starts the engine again.
  void testPromptRejected() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-engine-XXXXXX"};
    const std::string started = std::string{directory.path()} + "/started";
    const ds::Array<std::string, 2> first_runs{
        R"(read -r line; printf '%s\n' '{"type":"response","command":"prompt","success":false}'; sleep 30)",
        "read -r line; exit 0",
    };

    for (const auto& first_run : first_runs) {
      std::filesystem::remove(started);
      const auto script = std::format("if [ -e '{}' ]; then {}; else touch '{}'; {}; fi", started, answering(), started, first_run);
      const ds::Array<std::string_view, 3> arguments{"/bin/sh", "-c", script};
      SuggestionEngine engine{memory, SuggestionOptions{.arguments = arguments, .timeout = std::chrono::seconds{10}}};
      const auto asked = std::chrono::steady_clock::now();
      std::string text;

      check(ask(engine, memory, 1) == SuggestionStatus::failed, first_run);
      check(std::chrono::steady_clock::now() - asked < std::chrono::seconds{5}, "a refused prompt waited for the timeout");
      check(ask(engine, memory, 2, &text) == SuggestionStatus::ready && text == "git status", "the engine was not started again");
    }
  }

  void testMissingEngineUnavailable() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const ds::Array<std::string_view, 1> arguments{"/nonexistent/telar-suggestion-engine"};
    SuggestionEngine engine{memory, SuggestionOptions{.arguments = arguments, .timeout = std::chrono::seconds{5}}};

    // Not configured on this host, which the GUI tells apart from an engine that broke.
    check(ask(engine, memory, 1) == SuggestionStatus::unavailable);
  }

  void testOversizedRecordSkipped() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    // A line that is no record, longer than the engine's whole input buffer, ahead of the answer:
    // the reader drops it as it streams in rather than waiting for its end.
    const auto junk = std::format("head -c {} /dev/zero | tr '\\0' x; printf '\\n';", 200 * 1024);
    const auto script = answering(junk);
    const ds::Array<std::string_view, 3> arguments{"/bin/sh", "-c", script};
    SuggestionEngine engine{memory, SuggestionOptions{.arguments = arguments, .timeout = std::chrono::seconds{5}}};
    std::string text;

    check(ask(engine, memory, 1, &text) == SuggestionStatus::ready && text == "git status");
  }

  void testStopAborts() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const ds::Array<std::string_view, 3> arguments{"/bin/sh", "-c", "while read -r line; do :; done"};
    SuggestionEngine engine{memory, SuggestionOptions{.arguments = arguments, .timeout = std::chrono::seconds{30}}};
    auto pending = std::async(std::launch::async, [&] {
      return ask(engine, memory, 1);
    });

    // The runtime stops while a request waits on an engine that never answers.
    std::this_thread::sleep_for(std::chrono::milliseconds{100});
    engine.stop();
    check(pending.wait_for(std::chrono::seconds{3}) == std::future_status::ready, "stopping waited for the engine's timeout");
    pending.get();
  }

  const telar::testing::Case case_prompt_rejected{"suggestion_engine.prompt_rejected", testPromptRejected};
  const telar::testing::Case case_missing_engine_unavailable{"suggestion_engine.missing_engine_unavailable", testMissingEngineUnavailable};
  const telar::testing::Case case_oversized_record_skipped{"suggestion_engine.oversized_record_skipped", testOversizedRecordSkipped};
  const telar::testing::Case case_stop_aborts{"suggestion_engine.stop_aborts", testStopAborts};

}

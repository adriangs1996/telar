#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cassert>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <sys/types.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.base.text.json;
import telar.platform.primitives;
import telar.testing;
import telar.runtime.editors.remote_editor;
import telar.runtime.paths.query_task;
import telar.runtime.platform.request_worker;
import telar.runtime.suggestions.engine;
import telar.wire.clients;
import telar.wire.editor;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.platform.error;
import telar.platform.process;
import telar.runtime.platform.background_executor;
import telar.runtime.transport.connection;
import telar.runtime.platform.process_probe;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  void testJson(ConcurrentMemory& memory) {
    String<ConcurrentMemory> text{AllocatorRef<char, ConcurrentMemory>{memory}};
    const auto object = JsonValue::parse(R"({"type":"response","data":{"text":"printf \"caf\u00e9\" \ud83d\ude42"},"success":true})");

    check(object.field("type")->equals("response") && object.field("success")->boolean());
    object.field("data")->field("text")->string(text);
    check(text == "printf \"café\" 🙂");
    text.clear();
    appendJsonText(text, "\t\n\"\\");
    String<ConcurrentMemory> decoded{AllocatorRef<char, ConcurrentMemory>{memory}};

    JsonValue::parse(text).string(decoded);
    check(decoded == "\t\n\"\\");
    for (const auto invalid : {"{", "[1,]", "{\"x\":}", "\"\\q\"", "true false", "NaN", "01", "-", "1.", "1e"}) {
      bool rejected = false;

      try {
        JsonValue::parse(invalid);
      } catch (const JsonError&) {
        rejected = true;
      }

      check(rejected);
    }
  }

  struct MalformedJsonService {
    void process(std::span<const Byte>, EncodedReply<ConcurrentMemory>&) {
      JsonValue::parse("{");
    }
  };

  static void testJsonFailure(ConcurrentMemory& memory) {
    MalformedJsonService service;
    RequestWorker worker{memory, service};

    worker.submit(7, QueryClients{.request_id = 42});
    pollfd ready{.fd = worker.descriptor(), .events = POLLIN, .revents = 0};

    check(::poll(&ready, 1, 2000) == 1);
    bool received = false;

    worker.collect([&](std::uint64_t client, ClientTag, std::span<const Byte> payload) {
      ds::Array<Byte, 256> bytes;
      DecodeStorage storage{bytes.viewMut()};
      const auto failure = Codec::decode<RequestFailed>(payload, storage);

      check(client == 7 && failure.request_id == 42);
      check(failure.code == FailureCode::invalid_request && failure.message == "Invalid JSON record");
      received = true;
    });

    check(received && !worker.pending());
  }

  static void testSuggestions(ConcurrentMemory& memory) {
    constexpr std::string_view mock = "while IFS= read -r line; do case \"$line\" in *get_last_assistant_text*) printf '%s\\n' '{\"type\":\"response\",\"command\":\"get_last_assistant_text\",\"success\":true,\"data\":{\"text\":\"```sh\\ngit status\\n```\"}}';; *) printf '%s\\n' '{\"type\":\"response\",\"command\":\"prompt\",\"success\":true}' '{\"type\":\"agent_settled\"}';; esac; done";
    const ds::Array<std::string_view, 3> arguments{"/bin/sh", "-c", mock};
    SuggestionEngine engine{memory, SuggestionOptions{.arguments = arguments, .timeout = std::chrono::milliseconds{1000}}};
    EncodedReply reply{memory};
    ds::Array<Byte, 4096> scratch;
    DecodeStorage storage{scratch.viewMut()};

    for (unsigned index = 0; index < 2; ++index) {
      engine.suggest(SuggestCommand{.request_id = index + 1}, "Prompt with \"quotes\"\n", reply);
      const auto suggestion = Codec::decode<CommandSuggestion>(reply.payload(), storage);

      check(suggestion.status == SuggestionStatus::ready && suggestion.text == "git status");
    }

    SuggestionEngine unavailable{memory, SuggestionOptions{}};

    unavailable.suggest(SuggestCommand{.request_id = 3}, {}, reply);
    check(Codec::decode<CommandSuggestion>(reply.payload(), storage).status == SuggestionStatus::unavailable);
    const ds::Array<std::string_view, 2> sleeping{"/bin/sleep", "5"};
    SuggestionEngine timeout{memory, SuggestionOptions{.arguments = sleeping, .timeout = std::chrono::milliseconds{50}}};

    timeout.suggest(SuggestCommand{.request_id = 4}, "hello", reply);
    check(Codec::decode<CommandSuggestion>(reply.payload(), storage).status == SuggestionStatus::timeout);
  }

  // A model's answer reaches a shell prompt: one carrying a control byte, such as the end of a
  // bracketed paste, or a line longer than a command, fails with no text.
  static void testSuggestionControlBytes(ConcurrentMemory& memory) {
    // The answer as the model's JSON carries it, and whether it may reach the prompt.
    const ds::Array<std::pair<std::string, bool>, 6> answers{{
        {"git status", true},
        {R"(rm -rf ~\u001b[201~)", false},
        {R"(`rm -rf ~\u001b[201~`)", false},
        {R"(a\rb)", false},
        {R"(printf \u0007)", false},
        {std::string(1025, 'x'), false},
    }};

    for (std::size_t index = 0; index < answers.size(); ++index) {
      const auto& [text, accepted] = answers[index];
      const auto mock = "while IFS= read -r line; do case \"$line\" in *get_last_assistant_text*) printf '%s\\n' '{\"type\":\"response\",\"command\":\"get_last_assistant_text\",\"success\":true,\"data\":{\"text\":\"" + text + "\"}}';; *) printf '%s\\n' '{\"type\":\"response\",\"command\":\"prompt\",\"success\":true}' '{\"type\":\"agent_settled\"}';; esac; done";
      const ds::Array<std::string_view, 3> arguments{"/bin/sh", "-c", mock};
      SuggestionEngine engine{memory, SuggestionOptions{.arguments = arguments, .timeout = std::chrono::milliseconds{2000}}};
      EncodedReply reply{memory};
      ds::Array<Byte, 4096> scratch;
      DecodeStorage storage{scratch.viewMut()};

      engine.suggest(SuggestCommand{.request_id = index + 1}, "Prompt", reply);
      const auto suggestion = Codec::decode<CommandSuggestion>(reply.payload(), storage);

      if (accepted) {
        check(suggestion.status == SuggestionStatus::ready && suggestion.text == text);
      } else {
        check(suggestion.status == SuggestionStatus::failed && suggestion.text.empty(), text);
      }
    }
  }

  static void testPaths(ConcurrentMemory& memory) {
    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-path-test.XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
    const std::filesystem::path root{directory.data()};

    std::filesystem::create_directories(root / "src" / "nested");
    std::filesystem::create_directory(root / ".hidden");
    std::ofstream{root / "src" / "runtime.cpp"} << "fixture";
    std::ofstream{root / "src" / "nested" / "RuntimeTest.cpp"} << "fixture";
    std::ofstream{root / ".hidden" / "ignored.cpp"} << "fixture";
    std::filesystem::create_directory_symlink(root, root / "cycle");

    PathIndex index{memory};
    const FindPaths cached_query{.request_id = 1, .root = directory.data(), .query = "rt", .limit = 10};

    check(!index.canQueryInline(cached_query));
    EncodedReply reply{memory};
    ds::Array<Byte, 32768> scratch;
    DecodeStorage storage{scratch.viewMut()};

    index.query(FindPaths{.request_id = 1, .root = directory.data(), .query = "rt", .kind = PathKindFilter::files, .limit = 10}, reply);
    const auto result = Codec::decode<PathResults>(reply.payload(), storage);

    check(result.complete && !result.truncated && result.matches.size() == 2);
    check(index.canQueryInline(cached_query));
    auto refreshed_query = cached_query;

    refreshed_query.refresh = true;
    check(!index.canQueryInline(refreshed_query));
    for (const auto& match : result.matches) {
      check(match.positions.size() == 2);
      check(std::tolower(match.path[match.positions[0]]) == 'r' && std::tolower(match.path[match.positions[1]]) == 't');
    }

    index.query(FindPaths{.request_id = 2, .root = directory.data(), .kind = PathKindFilter::directories, .limit = 10}, reply);
    const auto directories = Codec::decode<PathResults>(reply.payload(), storage);

    check(directories.matches.size() == 2 && directories.matches[0].path == "src/");
    std::filesystem::remove_all(root);
  }

  static void testMissingEditor(ConcurrentMemory& memory) {
    RemoteEditor editor{memory};
    EncodedReply reply{memory};

    editor.open(OpenEditor{.request_id = 1, .pane_id = 2, .path = "/nonexistent-telar-editor-fixture", .line = 1, .column = 1}, RequestContext{}, reply);
    ds::Array<Byte, 1024> scratch;
    DecodeStorage storage{scratch.viewMut()};

    check(Codec::decode<EditorOpened>(reply.payload(), storage).outcome == EditorOutcome::missing);
  }

  static void testNeovimEditor(ConcurrentMemory& memory) {
    try {
      Command locate{memory, Launch{.cwd = "/tmp", .arguments = ds::Array<std::string_view, 2>{"nvim", "--version"}}, CommandPurpose::administration};
      CommandOutput version{memory, 16384};
      if (version.run(locate, std::chrono::steady_clock::now() + std::chrono::seconds{3}) != 0) {
        telar::testing::skip("nvim does not run");
      }
    } catch (const SystemError& error) {
      if (error.code() == ENOENT) {
        telar::testing::skip("nvim is not installed");
      }

      throw;
    }

    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-editor-test.XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
    const std::filesystem::path root{directory.data()};
    const auto endpoint = (root / "nvim.fixture").string();
    const auto filename = (root / "quote's file.txt").string();

    std::ofstream{filename} << "first\nsecond line\nthird\n";
    const char* previous = std::getenv("XDG_RUNTIME_DIR");
    const ds::Option<std::string> original = previous == nullptr ? ds::none : ds::Option{std::string{previous}};

    check(::setenv("XDG_RUNTIME_DIR", directory.data(), 1) == 0);
    {
      const ds::Array<std::string_view, 8> arguments{"nvim", "--headless", "-u", "NONE", "-i", "NONE", "--listen", endpoint};
      Command launch{memory, Launch{.cwd = directory.data(), .arguments = arguments}, CommandPurpose::administration};
      PipeProcess process{launch.specification({})};
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{3};

      while (!std::filesystem::exists(endpoint)) {
        check(std::chrono::steady_clock::now() < deadline && !process.reap());
        ::poll(nullptr, 0, 5);
      }

      RequestContext context;
      const auto identity = ProcessInspector{}.identity(process.processId());

      check(identity.hasValue());
      context.editor_candidates.atMut(0) = {.pane = 7, .generation = 9, .process = *identity};
      context.editor_candidate_count = 1;
      RemoteEditor editor{memory};
      EncodedReply reply{memory};

      editor.open(OpenEditor{.request_id = 1, .editor = "nvim", .path = filename, .line = 2, .column = 3}, context, reply);
      ds::Array<Byte, 1024> scratch;
      DecodeStorage storage{scratch.viewMut()};
      const auto opened = Codec::decode<EditorOpened>(reply.payload(), storage);

      check(opened.outcome == EditorOutcome::opened && opened.pane_id == 7 && opened.pane_generation == 9);
      const ds::Array<std::string_view, 5> query{"nvim", "--server", endpoint, "--remote-expr", R"(expand('%:p') . "\n" . line('.') . ':' . col('.'))"};
      Command inspect{memory, Launch{.cwd = directory.data(), .arguments = query}, CommandPurpose::administration};
      CommandOutput result{memory, 16384};

      check(result.run(inspect, std::chrono::steady_clock::now() + std::chrono::seconds{3}) == 0);
      check(result.text() == filename + "\n2:3");

      ++context.editor_candidates.atMut(0).process.started_seconds;
      editor.open(OpenEditor{.request_id = 2, .editor = "nvim", .path = filename}, context, reply);
      check(Codec::decode<EditorOpened>(reply.payload(), storage).outcome == EditorOutcome::unavailable);
    }

    if (original) {
      ::setenv("XDG_RUNTIME_DIR", original->c_str(), 1);
    } else {
      ::unsetenv("XDG_RUNTIME_DIR");
    }

    std::filesystem::remove_all(root);
  }

  static void testBackgroundServices() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;

    testJson(memory);
    testJsonFailure(memory);
    testSuggestions(memory);
    testPaths(memory);
    testMissingEditor(memory);
  }

  static void testNeovim() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;

    testNeovimEditor(memory);
  }

  static const telar::testing::Case case_background_services{"background_services.background_services", testBackgroundServices};
  static const telar::testing::Case case_neovim{"background_services.neovim", testNeovim};
  static const telar::testing::Case case_suggestion_control_bytes{"background_services.suggestion_control_bytes", [] {
                                                                    SystemAllocator system;
                                                                    MemoryAdapter adapter{system};

                                                                    testSuggestionControlBytes(adapter);
                                                                  }};

}

#include "check.hpp"
#include "editors/remote_editor.hpp"
#include "paths/path_index.hpp"
#include "suggestions/engine.hpp"
#include <filesystem>
#include <fstream>

using namespace telar;
using namespace telar::runtime;

static void testJson(SystemAllocator &memory) {
  String<SystemAllocator> text{AllocatorRef<char, SystemAllocator>{memory}};
  const auto object = JsonValue::parse(R"({"type":"response","data":{"text":"printf \"caf\u00e9\" \ud83d\ude42"},"success":true})");
  check(object.field("type")->equals("response") && object.field("success")->boolean());
  object.field("data")->field("text")->string(text);
  check(text == "printf \"café\" 🙂");
  text.clear();
  appendJsonString(text, "\t\n\"\\");
  String<SystemAllocator> decoded{AllocatorRef<char, SystemAllocator>{memory}};
  JsonValue::parse(text).string(decoded);
  check(decoded == "\t\n\"\\");
  for (const auto invalid : {"{", "[1,]", "{\"x\":}", "\"\\q\"", "true false", "NaN", "01", "-", "1.", "1e"}) {
    bool rejected = false;
    try {
      JsonValue::parse(invalid);
    } catch (const RequestError &) {
      rejected = true;
    }
    check(rejected);
  }
}

static void testSuggestions(SystemAllocator &memory) {
  constexpr std::string_view mock = "while IFS= read -r line; do case \"$line\" in *get_last_assistant_text*) printf '%s\\n' '{\"type\":\"response\",\"command\":\"get_last_assistant_text\",\"success\":true,\"data\":{\"text\":\"```sh\\ngit status\\n```\"}}';; *) printf '%s\\n' '{\"type\":\"response\",\"command\":\"prompt\",\"success\":true}' '{\"type\":\"agent_settled\"}';; esac; done";
  const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", mock};
  SuggestionEngine engine{memory, SuggestionOptions{.arguments = arguments,
                                                    .timeout = std::chrono::milliseconds{1000}}};
  EncodedReply reply{memory};
  std::array<Byte, 4096> scratch;
  DecodeStorage storage{scratch};
  for (unsigned index = 0; index < 2; ++index) {
    engine.suggest(SuggestCommand{.request_id = index + 1}, "Prompt with \"quotes\"\n", reply);
    const auto suggestion = Codec::decode<CommandSuggestion>(reply.payload(), storage);
    check(suggestion.status == SuggestionStatus::ready && suggestion.text == "git status");
  }

  SuggestionEngine unavailable{memory, SuggestionOptions{}};
  unavailable.suggest(SuggestCommand{.request_id = 3}, {}, reply);
  check(Codec::decode<CommandSuggestion>(reply.payload(), storage).status == SuggestionStatus::unavailable);
  const std::array<std::string_view, 2> sleeping{"/bin/sleep", "5"};
  SuggestionEngine timeout{memory, SuggestionOptions{.arguments = sleeping,
                                                     .timeout = std::chrono::milliseconds{50}}};
  timeout.suggest(SuggestCommand{.request_id = 4}, "hello", reply);
  check(Codec::decode<CommandSuggestion>(reply.payload(), storage).status == SuggestionStatus::timeout);
}

static void testPaths(SystemAllocator &memory) {
  std::array<char, 64> directory{};
  std::strcpy(directory.data(), "/tmp/telar-path-test.XXXXXX");
  check(::mkdtemp(directory.data()) != nullptr);
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
  std::array<Byte, 32768> scratch;
  DecodeStorage storage{scratch};
  index.query(FindPaths{.request_id = 1,
                        .root = directory.data(),
                        .query = "rt",
                        .kind = PathKindFilter::files,
                        .limit = 10},
              reply);
  const auto result = Codec::decode<PathResults>(reply.payload(), storage);
  check(result.complete && !result.truncated && result.matches.size() == 2);
  check(index.canQueryInline(cached_query));
  auto refreshed_query = cached_query;
  refreshed_query.refresh = true;
  check(!index.canQueryInline(refreshed_query));
  for (const auto &match : result.matches) {
    check(match.positions.size() == 2);
    check(std::tolower(match.path[match.positions[0]]) == 'r' && std::tolower(match.path[match.positions[1]]) == 't');
  }
  index.query(FindPaths{.request_id = 2,
                        .root = directory.data(),
                        .kind = PathKindFilter::directories,
                        .limit = 10},
              reply);
  const auto directories = Codec::decode<PathResults>(reply.payload(), storage);
  check(directories.matches.size() == 2 && directories.matches[0].path == "src/");
  std::filesystem::remove_all(root);
}

static void testMissingEditor(SystemAllocator &memory) {
  RemoteEditor editor{memory};
  EncodedReply reply{memory};
  editor.open(OpenEditor{.request_id = 1,
                         .pane_id = 2,
                         .path = "/nonexistent-telar-editor-fixture",
                         .line = 1,
                         .column = 1},
              RequestContext{}, reply);
  std::array<Byte, 1024> scratch;
  DecodeStorage storage{scratch};
  check(Codec::decode<EditorOpened>(reply.payload(), storage).outcome == EditorOutcome::missing);
}

static void testNeovimEditor(SystemAllocator &memory) {
  try {
    Command locate{memory, Launch{.cwd = "/tmp", .arguments = std::array<std::string_view, 2>{"nvim", "--version"}}, CommandPurpose::administration};
    CommandOutput version{memory, 16384};
    if (version.run(locate, std::chrono::steady_clock::now() + std::chrono::seconds{3}) != 0) {
      return;
    }
  } catch (const SystemError &error) {
    if (error.code() == ENOENT) {
      std::puts("Neovim integration skipped: nvim is not installed");
      return;
    }
    throw;
  }

  std::array<char, 64> directory{};
  std::strcpy(directory.data(), "/tmp/telar-editor-test.XXXXXX");
  check(::mkdtemp(directory.data()) != nullptr);
  const std::filesystem::path root{directory.data()};
  const auto endpoint = (root / "nvim.fixture").string();
  const auto filename = (root / "quote's file.txt").string();
  std::ofstream{filename} << "first\nsecond line\nthird\n";
  const char *previous = std::getenv("XDG_RUNTIME_DIR");
  const std::optional<std::string> original = previous == nullptr ? std::nullopt : std::optional{std::string{previous}};
  check(::setenv("XDG_RUNTIME_DIR", directory.data(), 1) == 0);
  {
    const std::array<std::string_view, 8> arguments{"nvim", "--headless", "-u", "NONE", "-i", "NONE", "--listen", endpoint};
    Command launch{memory, Launch{.cwd = directory.data(), .arguments = arguments}, CommandPurpose::administration};
    PipeProcess process{launch.specification({})};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{3};
    while (!std::filesystem::exists(endpoint)) {
      check(std::chrono::steady_clock::now() < deadline && !process.reap());
      ::poll(nullptr, 0, 5);
    }
    RequestContext context;
    const auto identity = ProcessInspector{}.identity(process.processId());
    check(identity.has_value());
    context.editor_candidates[0] = {.pane = 7,
                                    .generation = 9,
                                    .process = *identity};
    context.editor_candidate_count = 1;
    RemoteEditor editor{memory};
    EncodedReply reply{memory};
    editor.open(OpenEditor{.request_id = 1,
                           .editor = "nvim",
                           .path = filename,
                           .line = 2,
                           .column = 3},
                context, reply);
    std::array<Byte, 1024> scratch;
    DecodeStorage storage{scratch};
    const auto opened = Codec::decode<EditorOpened>(reply.payload(), storage);
    check(opened.outcome == EditorOutcome::opened && opened.pane_id == 7 && opened.pane_generation == 9);
    const std::array<std::string_view, 5> query{"nvim", "--server", endpoint, "--remote-expr", R"(expand('%:p') . "\n" . line('.') . ':' . col('.'))"};
    Command inspect{memory, Launch{.cwd = directory.data(), .arguments = query}, CommandPurpose::administration};
    CommandOutput result{memory, 16384};
    check(result.run(inspect, std::chrono::steady_clock::now() + std::chrono::seconds{3}) == 0);
    check(result.text() == filename + "\n2:3");

    ++context.editor_candidates[0].process.started_seconds;
    editor.open(OpenEditor{.request_id = 2,
                           .editor = "nvim",
                           .path = filename},
                context, reply);
    check(Codec::decode<EditorOpened>(reply.payload(), storage).outcome == EditorOutcome::unavailable);
  }
  if (original) {
    ::setenv("XDG_RUNTIME_DIR", original->c_str(), 1);
  } else {
    ::unsetenv("XDG_RUNTIME_DIR");
  }
  std::filesystem::remove_all(root);
}

void testBackgroundServices() {
  SystemAllocator memory;
  testJson(memory);
  testSuggestions(memory);
  testPaths(memory);
  testMissingEditor(memory);
  testNeovimEditor(memory);
}

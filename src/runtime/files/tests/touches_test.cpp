#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.platform.fs;
import telar.runtime.files.touches;
import telar.runtime.transport.connection;
import telar.wire.files;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  struct Seen {
    std::string path;
    std::string verb;
    TouchActor actor = TouchActor::user;
    AgentProvider provider = AgentProvider::unknown;
    std::uint64_t pane = 0;
    std::uint64_t seconds = 0;
  };

  struct Answer {
    std::vector<Seen> touches;
    bool truncated = false;
  };

  Answer ask(ConcurrentMemory& memory, TouchIndex& index, std::string_view path) {
    EncodedReply reply{memory};
    std::vector<Byte> scratch(std::size_t{1024} * 1024);
    DecodeStorage storage{scratch};

    index.answer(QueryTouches{.request_id = 5, .path = path}, reply);

    const auto listed = Codec::decode<FileTouches>(reply.payload(), storage);
    Answer answer{.truncated = listed.truncated};

    check(listed.request_id == 5 && listed.path == path);
    for (const auto& touch : listed.touches) {
      answer.touches.push_back({std::string{touch.path}, std::string{touch.verb}, touch.actor, touch.provider, touch.pane_id, touch.seconds});
    }

    return answer;
  }

  void write(const std::string& path) {
    std::ofstream{path} << "text\n";
  }

  std::uint64_t now() {
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count());
  }

  void testACommandTouchesTheFilesItNames() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const TemporaryDirectory directory{"/tmp/telar-touches-XXXXXX"};
    const std::string root{directory.path()};
    TouchIndex index{memory};

    std::filesystem::create_directories(root + "/docs/guides");
    write(root + "/docs/usage.md");
    write(root + "/docs/guides/my notes.md");
    write(root + "/README.md");

    index.note({.pane = 3, .text = "rg -n split docs/usage.md './docs/guides/my notes.md' missing.md docs", .directory = root, .seconds = now() - 60});

    const auto seen = ask(memory, index, root);

    check(seen.touches.size() == 2 && !seen.truncated, "the files it names, not its flags, what is not there or a directory");
    check(seen.touches[0].path == root + "/docs/guides/my notes.md" && seen.touches[1].path == root + "/docs/usage.md", "the last named first");
    check(seen.touches[0].verb == "rg" && seen.touches[0].actor == TouchActor::user && seen.touches[0].pane == 3 && seen.touches[0].seconds == seen.touches[1].seconds);

    // The program's own path is no part of the verb, and a path that leaves the directory is no touch.
    index.note({.pane = 3, .text = "/usr/bin/sed -i s/a/b/ ../outside.md /etc/hosts docs/../README.md", .directory = root + "/docs", .seconds = now()});
    check(ask(memory, index, root).touches.size() == 2, "a path outside where the pane was is ignored, however it is spelled");
    index.note({.pane = 3, .text = "/usr/bin/sed -i s/a/b/ guides/../usage.md", .directory = root + "/docs", .seconds = now()});

    const auto again = ask(memory, index, root + "/docs");

    check(again.touches.size() == 3 && again.touches[0].path == root + "/docs/usage.md" && again.touches[0].verb == "sed", "the newest first, with its dots taken out");
    check(ask(memory, index, root + "/docs/guides").touches.size() == 1, "an answer is of what is below the directory asked");

    // The same hand and verb on the same file is one touch: the last time.
    index.note({.pane = 3, .text = "rg usage docs/usage.md", .directory = root, .seconds = now()});
    check(ask(memory, index, root).touches.size() == 3 && ask(memory, index, root).touches[0].verb == "rg");
  }

  void testAnAgentsToolTouchesTheFileItIsGiven() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const TemporaryDirectory directory{"/tmp/telar-touches-XXXXXX"};
    const std::string root{directory.path()};
    TouchIndex index{memory};

    std::filesystem::create_directories(root + "/src");
    write(root + "/src/main one.cpp");
    write(root + "/src/query.cpp");

    index.note({.pane = 1, .actor = TouchActor::agent, .provider = AgentProvider::claude, .text = "» Edit " + root + "/src/main one.cpp", .directory = root, .seconds = now()});
    index.note({.pane = 1, .actor = TouchActor::agent, .provider = AgentProvider::claude, .text = "» Bash rg split src/query.cpp", .directory = root, .seconds = now()});
    index.note({.pane = 1, .actor = TouchActor::agent, .provider = AgentProvider::claude, .text = "» Edit " + root + "/src/cut-by-the-line-", .directory = root, .seconds = now()});
    index.note({.pane = 1, .actor = TouchActor::agent, .provider = AgentProvider::claude, .text = "Reading the sources", .directory = root, .seconds = now()});

    const auto seen = ask(memory, index, root);

    check(seen.touches.size() == 2, "a tool's path with a blank in it is one file; a path the line cut is none");
    check(seen.touches[1].path == root + "/src/main one.cpp" && seen.touches[1].verb == "Edit" && seen.touches[1].actor == TouchActor::agent && seen.touches[1].provider == AgentProvider::claude);
    check(seen.touches[0].path == root + "/src/query.cpp" && seen.touches[0].verb == "Bash", "a tool that runs a command touches the files the command names");
  }

  void testTheIndexIsBounded() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const TemporaryDirectory directory{"/tmp/telar-touches-XXXXXX"};
    const std::string root{directory.path()};
    TouchIndex index{memory};

    write(root + "/old.md");
    write(root + "/new.md");
    index.note({.pane = 1, .text = "cat old.md", .directory = root, .seconds = now() - TouchIndex::kept_seconds - 60});
    index.note({.pane = 1, .text = "cat new.md", .directory = root, .seconds = now()});
    check(ask(memory, index, root).touches.size() == 1 && ask(memory, index, root).touches[0].path == root + "/new.md", "a touch older than a day is gone");

    // More notes than wait at once: the oldest give way, and nothing grows past its bound.
    for (std::size_t note = 0; note < TouchIndex::pending_notes + 40; ++note) {
      index.note({.pane = note + 10, .text = "cat new.md", .directory = root, .seconds = now()});
    }

    const auto many = ask(memory, index, root);

    check(many.touches.size() == FileLimits::maximum_touches && many.truncated, "an answer holds so many, and says there are more");

    bool refused = false;

    try {
      static_cast<void>(ask(memory, index, "relative"));
    } catch (const RequestError&) {
      refused = true;
    }

    check(refused, "a directory is asked by its absolute path");
    index.note({.pane = 1, .text = "cat new.md", .directory = "relative", .seconds = now()});
    index.note({.pane = 1, .text = "", .directory = root, .seconds = now()});
  }

  const telar::testing::Case case_command{"touches.a_command_touches_the_files_it_names", testACommandTouchesTheFilesItNames};
  const telar::testing::Case case_agent{"touches.an_agents_tool_touches_the_file_it_is_given", testAnAgentsToolTouchesTheFileItIsGiven};
  const telar::testing::Case case_bounded{"touches.the_index_is_bounded", testTheIndexIsBounded};

}

#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdint>
#include <cstring>
#include <sys/types.h>
#include <unistd.h>
#include <cstddef>
#include <sqlite3.h>
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>

import std;
import telar.base.memory;
import telar.base.text;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.tests.check;
import telar.runtime.agents.snapshot;

using namespace telar;
using namespace telar::runtime;

static void writeSessionFile(const std::string &path, std::string_view contents, bool append = false) {
  std::ofstream file{path, std::ios::binary | (append ? std::ios::app : std::ios::trunc)};
  file << contents;
  check(file.good());
}

static void testTranscript(SessionFileReader<SystemAllocator> &reader, const std::string &root) {
  const auto path = root + "/claude.jsonl";
  writeSessionFile(path, "{\"type\":\"custom-title\",\"sessionId\":\"session\",\"customTitle\":\"old title\"}\n");
  SessionFileRequest request;
  request.watch.configure("session", path, AgentSessionFileKind::claude_transcript);
  auto result = reader.observe(request);
  check(result.offset == std::filesystem::file_size(path) && !result.title);
  request.watch.offset = result.offset;
  writeSessionFile(path, "{\"type\":\"custom-title\",\"sessionId\":\"session\",\"customTitle\":\"new café title\"}\n{\"type\":\"custom-title\",\"sessionId\":\"other\",\"customTitle\":\"foreign\"}\n", true);
  result = reader.observe(request);
  check(result.title && result.title->view() == "new café title");
  request.watch.offset = result.offset;
  writeSessionFile(path, "{\"type\":\"custom-title\",\"sessionId\":\"session\",\"customTitle\":\"partial", true);
  result = reader.observe(request);
  check(!result.title && result.offset == request.watch.offset);
  writeSessionFile(path, " title\"}\n", true);
  result = reader.observe(request);
  check(result.title && result.title->view() == "partial title");
  request.watch.offset = result.offset;
  writeSessionFile(path, "{\"type\":\"custom-title\",\"sessionId\":\"session\"}\n");
  result = reader.observe(request);
  check(result.title && result.title->view().empty());

  std::filesystem::remove(path);
  request.watch.offset.reset();
  result = reader.observe(request);
  check(result.offset == 0 && !result.title);
  request.watch.offset = result.offset;
  writeSessionFile(path, std::string(64 * 1024, 'x'));
  result = reader.observe(request);
  check(result.offset == 64 * 1024 && !result.title);
  request.watch.offset = result.offset;
  writeSessionFile(path, "\n{\"type\":\"custom-title\",\"sessionId\":\"session\",\"customTitle\":\"after long line\"}\n", true);
  result = reader.observe(request);
  check(result.title && result.title->view() == "after long line");
}

static void testCursorMetadata(SessionFileReader<SystemAllocator> &reader, const std::string &root) {
  const auto directory = root + "/0192-abcd";
  std::filesystem::create_directory(directory);
  const auto path = directory + "/meta.json";
  SessionFileRequest request;
  request.watch.configure("0192-abcd", path, AgentSessionFileKind::cursor_meta);
  writeSessionFile(path, "{\"title\":\"Cursor title\"}");
  auto result = reader.observe(request);
  check(result.title && result.title->view() == "Cursor title");
  request.watch.session.assign("other");
  check(!reader.observe(request).title);
  request.watch.session.assign("0192-abcd");
  for (const auto input : {"{", "[]", "{\"title\":null}", "{\"title\":\"a\",\"title\":\"b\"}"}) {
    writeSessionFile(path, input);
    check(!reader.observe(request).title);
  }

  writeSessionFile(path, "{\"title\":\"" + std::string(95, 'a') + "好\"}");
  result = reader.observe(request);
  check(result.title && result.title->view() == std::string(95, 'a'));
  writeSessionFile(path, "{}");
  result = reader.observe(request);
  check(result.title && result.title->view().empty());
  writeSessionFile(path, std::string(16 * 1024, ' '));
  check(!reader.observe(request).title);
  std::filesystem::remove(path);
  check(::mkfifo(path.c_str(), 0600) == 0);
  check(!reader.observe(request).title);
}

static void testCodexDatabase(SessionFileReader<SystemAllocator> &reader, const std::string &root) {
  const auto path = root + "/codex.sqlite";
  SessionFileRequest request;
  request.watch.configure("thread", path, AgentSessionFileKind::codex_state);
  check(!reader.observe(request).title && !std::filesystem::exists(path));
  Database database{path.c_str()};
  database.execute("CREATE TABLE threads(id TEXT PRIMARY KEY, name TEXT)");
  database.execute("INSERT INTO threads VALUES('thread','Codex title')");
  auto result = reader.observe(request);
  check(result.title && result.title->view() == "Codex title");
  database.execute("UPDATE threads SET name=NULL");
  result = reader.observe(request);
  check(result.title && result.title->view().empty());
  database.execute("DELETE FROM threads");
  check(!reader.observe(request).title);
  Database read_only{path.c_str(), DatabaseAccess::read_only};
  check(!read_only.tryExecute("INSERT INTO threads VALUES('thread','forbidden')"));
}

static void testWatchAndTitle() {
  SessionFileWatch watch;
  watch.configure("session", "/tmp/a", AgentSessionFileKind::claude_transcript);
  const auto revision = watch.revision;
  watch.offset = 19;
  check(watch.remember("title") && !watch.remember("title"));
  watch.configure("session", "/tmp/a", AgentSessionFileKind::claude_transcript);
  check(watch.offset == 19 && watch.revision == revision);
  watch.configure("changed", "/tmp/a", AgentSessionFileKind::claude_transcript);
  check(!watch.offset && !watch.last_title && watch.revision != revision);

  Agent agent{1, 1};
  agent.title.assign("Generated");
  agent.title_source = AgentTitleSource::generated;
  agent.title_state = AgentTitleState::ready;
  check(!agent.reportTitle({}) && agent.title.view() == "Generated");
  check(agent.reportTitle("Agent title") && agent.title_source == AgentTitleSource::agent);
  check(!agent.reportTitle("Agent title"));
  check(agent.reportTitle({}) && agent.title_source == AgentTitleSource::telar && agent.title.view().empty());
}

void testSessionFiles() {
  SystemAllocator memory;
  SessionFileReader reader{memory};
  std::array<char, 64> temporary{};
  std::strcpy(temporary.data(), "/tmp/telar-session-file-XXXXXX");
  check(::mkdtemp(temporary.data()) != nullptr);
  const std::string root{temporary.data()};
  testTranscript(reader, root);
  testCursorMetadata(reader, root);
  testCodexDatabase(reader, root);
  testWatchAndTitle();
  std::filesystem::remove_all(root);
}

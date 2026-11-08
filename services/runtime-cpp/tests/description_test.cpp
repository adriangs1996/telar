#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include <chrono>
#include <cstdint>
#include <limits>
#include <optional>
#include "telar_base/text/utf8.hpp"
#include <cstring>
#include <span>
#include <sys/types.h>
#include <unistd.h>
#include <cstddef>
#include <stdexcept>
#include "telar_base/memory/allocator.hpp"
#include <cassert>
#include <exception>
#include "telar_base/program_identity.hpp"
#include <cerrno>
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <limits.h>
#include <atomic>
#include <poll.h>
#include <sys/wait.h>
#include "telar_platform/trace.hpp"
#include "check.hpp"
#include <sqlite3.h>
#include <concepts>
#include <condition_variable>
#include <pthread.h>
#include <thread>



import telar.runtime.agents.snapshot;
import telar.runtime.agents.description_generator;
import telar.runtime.history.store;
import telar.runtime.platform.request_worker;

using namespace telar;
using namespace telar::runtime;

static std::span<const Byte> inputBytes(std::string_view text) {
  return {reinterpret_cast<const Byte *>(text.data()), text.size()};
}

static void testQueryEditing() {
  const std::array cases{
      std::pair{"  Fix\t the   tests \rignored", "Fix the tests"},
      std::pair{"old\x15new\r", "new"},
      std::pair{"Fix wrong\x17parser\r", "Fix parser"},
      std::pair{"café\x7foffee\r", "cafoffee"},
      std::pair{"draft\x03replacement\r", "replacement"},
      std::pair{"Fix \x1b[200~multiple\nlines\tplease\x1b[201~\r", "Fix multiple lines please"},
      std::pair{"a\x1b[1;5Db\x1bxz\r", "abz"},
  };
  for (const auto &[raw, expected] : cases) {
    DescriptionCapture capture;
    bool submitted = false;
    for (const auto byte : inputBytes(raw)) {
      submitted |= capture.feed({&byte, 1});
    }

    check(submitted);
    check(capture.normalized().view() == expected);
    check(!capture.feed(inputBytes("second\r")));
    capture.clear();
    check(capture.feed(inputBytes("third\r")));
    check(capture.normalized().view() == "third");
  }

  for (const auto raw : {" \t\r", "\xc0\xaf\r", "\xed\xa0\x80\r", "\xf4\x90\x80\x80\r"}) {
    DescriptionCapture capture;
    capture.feed(inputBytes(raw));
    bool rejected = false;
    try {
      capture.normalized();
    } catch (const EncodingError &) {
      rejected = true;
    }
    check(rejected);
  }

  DescriptionCapture large;
  const std::string raw(description_query_capacity + 10, 'x');
  check(!large.feed(inputBytes(raw)));
  check(large.feed(inputBytes("\r")));
  check(large.normalized().view().size() == description_query_capacity);

  DescriptionQuery query;
  query.append("private request");
  const auto original = query.view();
  auto transferred = std::move(query);
  check(query.view().empty());
  check(std::ranges::all_of(original, [](char byte) { return byte == 0; }));
  const auto retained = transferred.view();
  transferred.clear();
  check(std::ranges::all_of(retained, [](char byte) { return byte == 0; }));
}

static void testGenerator(SystemAllocator &memory) {
  const std::array cases{
      std::pair{"cat >/dev/null; printf '  \"Fix café\"  \\n'", DescriptionStatus::success},
      std::pair{"cat >/dev/null; printf 'one\\ntwo'", DescriptionStatus::invalid_output},
      std::pair{"cat >/dev/null; printf '\\377'", DescriptionStatus::invalid_output},
      std::pair{"cat >/dev/null; printf '\\033'", DescriptionStatus::invalid_output},
      std::pair{"cat >/dev/null; exit 4", DescriptionStatus::failed},
      std::pair{"cat >/dev/null; head -c 513 /dev/zero", DescriptionStatus::invalid_output},
      std::pair{"cat >/dev/null; sleep 5", DescriptionStatus::timeout},
      std::pair{"cat >/dev/null; exec 1>&- 2>&-; sleep 5", DescriptionStatus::timeout},
      std::pair{"cat >/dev/null; :", DescriptionStatus::invalid_output},
  };
  DescriptionRequest request{.identity = {.pane = 2, .generation = 3, .revision = 4}};
  request.query.append("A private request");
  for (const auto &[script, expected] : cases) {
    const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", script};
    DescriptionGenerator generator{memory, DescriptionOptions{arguments, std::chrono::milliseconds{100}}};
    const auto result = generator.observe(request);
    check(result.identity == request.identity);
    check(result.status == expected);
    if (expected == DescriptionStatus::success) {
      check(result.title.view() == "Fix café");
    }
  }

  const std::array<std::string_view, 1> absent{"/nonexistent/telar-description-helper"};
  DescriptionGenerator missing{memory, DescriptionOptions{absent}};
  check(missing.observe(request).status == DescriptionStatus::unavailable);

  const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", "cat >/dev/null; sleep 60"};
  DescriptionGenerator generator{memory, DescriptionOptions{arguments, std::chrono::seconds{60}}};
  const auto started = std::chrono::steady_clock::now();
  {
    ObservationWorker<decltype(generator) &> worker{std::in_place, generator};
    check(worker.submit(request));
    std::this_thread::sleep_for(std::chrono::milliseconds{30});
  }
  check(std::chrono::steady_clock::now() - started < std::chrono::seconds{1});
}

static void testProcessInput(SystemAllocator &memory) {
  const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", "head -c 100000 /dev/zero >&2; wc -c"};
  Command command{memory, Launch{.cwd = "/", .arguments = arguments}, CommandPurpose::administration};
  CommandOutput output{memory, 64};
  const std::string body(100'000, 'x');
  const std::array<std::string_view, 3> fragments{body, {}, body};
  check(output.runWithInput(command, std::chrono::steady_clock::now() + std::chrono::seconds{2}, fragments) == 0);
  check(output.text().find("200000") != std::string_view::npos);
}

static void testTitlePersistence(SystemAllocator &memory) {
  Database database{":memory:"};
  migrateHistory(database);
  PaneHistoryWriter writer{database};
  HistorySession session{.pane = 7, .started_at_ms = 100, .workspace_path = "/project", .shell = "/bin/sh"};
  session.id[0] = 1;
  writer.persist(HistoryEventView{.kind = HistoryEventKind::session_started, .session = session});
  HistorySessionTitle title{.session = session.id, .source = AgentTitleSource::generated, .state = AgentTitleState::ready};
  title.title.assign("Fix parser");
  HistoryEvent owned{memory, HistoryEventView{.kind = HistoryEventKind::session_title, .session = {}, .title = title}};
  title.title.assign("Changed later");
  writer.persist(owned.view());
  Statement read{database, "SELECT title, title_source, title_state FROM session WHERE id=?1"};
  read.bind(1, std::span{session.id});
  check(read.next());
  check(read.text(0) == "Fix parser");
  check(read.integer(1) == static_cast<int>(AgentTitleSource::generated));
  check(read.integer(2) == static_cast<int>(AgentTitleState::ready));
  read.reset();

  title.title.assign({});
  title.source = AgentTitleSource::telar;
  title.state = AgentTitleState::failed;
  writer.persist(HistoryEventView{.kind = HistoryEventKind::session_title, .session = {}, .title = title});
  read.bind(1, std::span{session.id});
  check(read.next());
  check(read.text(0).empty() && !read.isNull(0));
  check(read.integer(2) == static_cast<int>(AgentTitleState::failed));
}

void testDescriptions() {
  SystemAllocator memory;
  testQueryEditing();
  testGenerator(memory);
  testProcessInput(memory);
  testTitlePersistence(memory);
}

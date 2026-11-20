#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <csignal>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.testing.test_memory;
import telar.runtime.platform.host_metrics;
import telar.runtime.platform.process_table;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // The listing holds every process, this one among them with its parent, its user and its time.
  void testListsThisProcess() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    ProcessTable table{memory};
    ds::Vec<ProcessRecord, ConcurrentMemory> records{memory};

    check(table.read(records));
    check(records.size() > 1);

    const auto self = std::ranges::find_if(records, [](const ProcessRecord& record) {
      return record.pid == ::getpid();
    });

    check(self != records.end());
    check(self->parent == ::getppid());
    check(self->user == ::geteuid());
    check(self->measured && self->resident_bytes > 0 && self->threads > 0);
    check(self->started_seconds > 0);

    const auto found = ProcessTable::find(::getpid());

    check(found && found->started_seconds == self->started_seconds && found->started_microseconds == self->started_microseconds);
    check(!ProcessTable::find(0));
  }

  // Reading again reuses the listing's storage.
  void testRereadKeepsStorage() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    ProcessTable table{memory};
    ds::Vec<ProcessRecord, ConcurrentMemory> records{memory};

    check(table.read(records));

    const auto capacity = records.capacity();

    check(table.read(records));
    check(records.capacity() >= capacity);
  }

  // The host reports its cores and memory; every core spent time.
  void testHostDetail() {
    NativeHostDetail probe;
    HostDetail detail;

    check(probe.read(detail));
    check(detail.core_count > 0);
    check(detail.memory_total_bytes > 0 && detail.memory_used_bytes <= detail.memory_total_bytes);
    check(detail.memory_used_bytes + detail.memory_available_bytes == detail.memory_total_bytes);
    for (std::size_t core = 0; core < detail.core_count; ++core) {
      check(detail.cores[core].total >= detail.cores[core].busy && detail.cores[core].total > 0);
    }

    for (std::size_t mount = 0; mount < detail.mount_count; ++mount) {
      check(!detail.mounts[mount].path.view().empty() && detail.mounts[mount].used_bytes <= detail.mounts[mount].total_bytes);
    }
  }

  // A signal or a priority reaches a process only while it is the instance the caller named.
  void testActsOnTheNamedInstance() {
    const auto child = ::fork();
    if (child == 0) {
      ::pause();
      ::_exit(0);
    }

    check(child > 0);
    const auto found = ProcessTable::find(child);

    check(found.hasValue());
    check(ProcessTable::signal({.pid = child, .started_seconds = found->started_seconds + 1}, SIGTERM) == ProcessActionResult::gone);
    check(ProcessTable::prioritize({.pid = child, .started_seconds = found->started_seconds, .started_microseconds = found->started_microseconds}, 5) == ProcessActionResult::done);
    check(::getpriority(PRIO_PROCESS, static_cast<id_t>(child)) == 5);
    check(ProcessTable::signal({.pid = child, .started_seconds = found->started_seconds, .started_microseconds = found->started_microseconds}, SIGTERM) == ProcessActionResult::done);

    int status = 0;

    check(::waitpid(child, &status, 0) == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM);
    check(ProcessTable::signal({.pid = child}, SIGTERM) == ProcessActionResult::gone);
  }

  const telar::testing::Case case_lists_this_process{"process_table.lists_this_process", testListsThisProcess};
  const telar::testing::Case case_reread_keeps_storage{"process_table.reread_keeps_storage", testRereadKeepsStorage};
  const telar::testing::Case case_acts_on_the_named_instance{"process_table.acts_on_the_named_instance", testActsOnTheNamedInstance};
  const telar::testing::Case case_host_detail{"process_table.host_detail", testHostDetail};

}

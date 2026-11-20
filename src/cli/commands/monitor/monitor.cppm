module;
#include "tbc/annotations.hpp"

export module telar.cli.commands.monitor;

import std;
import telar.tbc;

import telar.cli.console.command_limit;
import telar.cli.console.output;
import telar.wire.monitor;
import telar.base.memory.allocators;
import telar.base.ds;

// Interface: monitor.cppm
export {
  // `telar process` and `telar monitor`: the processes and the resources of the machine the runtime
  // runs on, read by that runtime.
  namespace telar::runtime::cli::monitor {

    enum class Command : std::uint8_t {
      process_list,
      process_get,
      process_watch,
      process_signal,
      process_renice,
      process_review,
      monitor_host,
      monitor_disks,
      monitor_network,
    };

    // What `process review` runs on the process.
    enum class ReviewTool : std::uint8_t {
      stack,
      files,
      logs,
      debug,
    };

    struct Options {
      static constexpr std::uint16_t default_watch_limit = 20;
      static constexpr unsigned default_interval_ms = 2000;

      Command command = Command::process_list;
      ds::Option<std::string_view> socket;
      bool json = false;
      MonitorSort sort = MonitorSort::cpu;
      bool reverse = false;
      MonitorScope scope = MonitorScope::all;
      bool tree = false;
      std::string_view filter;
      std::uint16_t limit = MonitorLimits::maximum_processes;
      ProcessInstance process{};
      ProcessSignal signal = ProcessSignal::terminate;
      std::int32_t nice = 0;
      ReviewTool tool = ReviewTool::stack;
      bool print = false;
      unsigned interval_ms = default_interval_ms;
      ds::Option<std::uint64_t> count;

      // The words after the family, `list` and its options for `telar process list`.
      static tbc::val_a<Options> parse(Family family, tbc::val_a<Arguments> words);
    };

    int run(Memory& memory, const Options& options);

  }
}

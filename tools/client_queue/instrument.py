#!/usr/bin/env python3
"""Instrument a disposable copy of the runtime to trace every client's outgoing queue.

Run it on a separate worktree, never on a checkout whose changes will be committed. It accepts the module
tree (src/runtime, the refactor) and the header tree (services/runtime-cpp, main before it), and applies
the same trace to both:

- every frame queued to a client, with the time it was queued and the time the last of its bytes left in
  a write() (kind message), or was discarded (dropped);
- every busy period of a queue, from empty to empty (drain);
- every write(): prepared bytes, written bytes and errno (write);
- in stop(), each client's queue before RuntimeStopping, after queuing it and after the one write()
  (snapshot, phases 0, 1 and 2), and the moment RuntimeStop was handled (stop_request).
- every publish(): how long each of its phases takes before the loop over the clients (publish).

Records are kept in memory and written once, at the end of stop(), to $QUEUE_TRACE_DIR/queue-<pid>.bin.
Without QUEUE_TRACE_DIR the trace stays off, but the copy is still instrumented: do not measure
performance with it outside this comparison. It also adds the pane-traffic-probe target.
"""
import argparse
from pathlib import Path

HERE = Path(__file__).resolve().parent


def replace_once(path, before, after):
    contents = path.read_text()
    if contents.count(before) != 1:
        raise SystemExit(f"{path}: instrumentation anchor changed:\n{before}")
    path.write_text(contents.replace(before, after))


def snippet(name):
    return (HERE / name).read_text()


def indent(text, prefix):
    return "".join(prefix + line if line.strip() else line for line in text.splitlines(keepends=True))


def module_tree(root):
    runtime = root / "src/runtime"
    interface = runtime / "transport/connection/connection.cppm"
    implementation = runtime / "transport/connection/connection.cpp"
    runtime_cpp = runtime / "runtime/runtime/runtime.cpp"
    marker = "QUEUE_TRACE_INLINE"
    if marker in interface.read_text():
        raise SystemExit(f"{interface} is already instrumented")

    replace_once(interface, "import telar.platform.net;\n", "import telar.platform.net;\n\n#define QUEUE_TRACE_INLINE\nexport {\n" + indent(snippet("trace_api.inc"), "  ") + "}\n")
    replace_once(interface, """          throw;
        }

        inserted(lane);
      }
""", """          throw;
        }

        inserted(lane);
        traceAppend(frame_prefix_size + size, lane);
      }
""")
    replace_once(interface, """        deferred_.append(bytes_.size(), request);
        inserted(DeliveryLane::management);
      }""", """        deferred_.append(bytes_.size(), request);
        inserted(DeliveryLane::management);
        traceDefer();
      }""")
    replace_once(interface, """        deferred_.resolved(resolved_size);
      }""", """        deferred_.resolved(resolved_size);
        traceInsert(offset, resolved_size, DeliveryLane::management);
      }""")
    replace_once(interface, """      std::uint64_t dropped() const noexcept;

    private:
""", """      std::uint64_t dropped() const noexcept;

""" + indent(snippet("trace_declarations.inc"), "    ") + """
    private:
""")
    replace_once(interface, """      std::size_t prepared_size_ = 0;
    };
""", """      std::size_t prepared_size_ = 0;
""" + indent(snippet("trace_state.inc"), "    ") + """    };
""")
    replace_once(interface, """        const auto count = ::write(descriptor_.get(), bytes.data(), bytes.size());
        if (count > 0) {
          output_.consume(static_cast<std::size_t>(count));
          return;
        }

        if (count < 0 && socketWouldBlock(sys::lastError())) {""", """        const auto started = queue_trace::now();
        const auto count = ::write(descriptor_.get(), bytes.data(), bytes.size());
        const int error = count < 0 ? sys::lastError() : 0;

        output_.traceWrite(started, bytes.size(), count, error);
        if (count > 0) {
          output_.consume(static_cast<std::size_t>(count));
          return;
        }

        if (count < 0 && socketWouldBlock(error)) {""")
    replace_once(interface, """      std::size_t queuedBytes() const noexcept;

      bool negotiated = false;""", """      std::size_t queuedBytes() const noexcept;

      void traceSnapshot(std::uint16_t phase) const noexcept {
        output_.traceSnapshot(phase);
      }

      bool negotiated = false;""")

    replace_once(implementation, """#include "telar_base/diagnostics/config.hpp"
""", """#include "telar_base/diagnostics/config.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#define QUEUE_TRACE_INLINE
""")
    replace_once(implementation, "module telar.runtime.transport.connection;\n", "module telar.runtime.transport.connection;\n\n" + snippet("trace_impl.inc"))
    frames_edits(implementation, "  ")
    replace_once(implementation, """  void OutgoingFrames<Memory>::clear() noexcept {
    bytes_.clear();""", """  void OutgoingFrames<Memory>::clear() noexcept {
    traceCleared();
    bytes_.clear();""")
    replace_once(implementation, """    active_offset_ = offset;
    active_remaining_ = frame.size;
  }
""", """    active_offset_ = offset;
    active_remaining_ = frame.size;
    trace_active_lane_ = frame.lane;
  }

""" + snippet("trace_members.inc"))

    stop_edits(runtime_cpp, "  void Runtime<Poller, Background>::handle(std::uint64_t, const RuntimeStop&) {\n    model_.stopping = true;", "    ", """      try {
        client->connection.send(RuntimeStopping{});
        client->connection.write(ResponseProjection{memory_, model_});
      } catch (...) {
      }

      dropClient(identity);
""", """    observations_.finish(model_);
    media_.finish(model_);
  }""")

    publish_edits(runtime_cpp, "    TELAR_TRACE(\"runtime.publish\");",
                  "    for (auto* pane : model_.panes.items()) {\n      if (pane != nullptr) {\n        try {\n          if (ClipboardService::advance(",
                  "    if (executions_.refresh(model_)) {", "    try {\n      observations_.refresh(model_, agents_);",
                  "    Worktrees::refresh(model_);", "    for (std::size_t slot = 0; slot < clients_.items().size(); ++slot) {\n      const auto* listed = clients_.items()[slot];")

    tests = runtime / "cmake/tests.cmake"
    replace_once(tests, "add_executable(checkpoint-probe tests/checkpoint_probe.cpp)\n", f"add_executable(checkpoint-probe tests/checkpoint_probe.cpp)\nadd_executable(pane-traffic-probe \"{HERE / 'pane_traffic_probe.cpp'}\")\ntarget_link_libraries(pane-traffic-probe PRIVATE runtime-core runtime-test-fixtures)\n")
    return runtime


def frames_edits(path, prefix):
    """OutgoingFrames edits whose text is the same in both trees once indented."""
    replace_once(path, f"""{prefix}  std::copy(payload.begin(), payload.end(), frame.begin());
{prefix}  inserted(lane);
{prefix}}}""", f"""{prefix}  std::copy(payload.begin(), payload.end(), frame.begin());
{prefix}  inserted(lane);
{prefix}  traceAppend(frame_prefix_size + payload.size(), lane);
{prefix}}}""")
    replace_once(path, f"""{prefix}  active_remaining_ -= remaining;
{prefix}  bytes_.erase(first_offset, count);
{prefix}  deferred_.eraseBytes(first_offset, count);
{prefix}  active_offset_ = first_offset;
{prefix}  prepared_size_ = 0;
{prefix}}}""", f"""{prefix}  active_remaining_ -= remaining;
{prefix}  traceConsumed(first_offset, count);
{prefix}  bytes_.erase(first_offset, count);
{prefix}  deferred_.eraseBytes(first_offset, count);
{prefix}  active_offset_ = first_offset;
{prefix}  prepared_size_ = 0;
{prefix}  traceDrained();
{prefix}}}""")


def publish_edits(path, start, panes, executions, observations, worktrees, clients):
    """Checkpoints inside publish(): its phases up to the loop that writes to the clients, one record per call."""
    marks = (("0", start), ("1", panes), ("2", executions), ("3", observations), ("4", worktrees), ("5", clients))
    for mark, anchor in marks:
        indentation = anchor[:len(anchor) - len(anchor.lstrip())]
        line = f"{indentation}const auto trace_publish_{mark} = queue_trace::now();\n"
        if mark == "0":
            replace_once(path, anchor, anchor + "\n" + line.rstrip("\n"))
        elif mark == "5":
            record = (f"{indentation}queue_trace::record({{.first = trace_publish_0, .second = trace_publish_5, "
                      ".bytes = static_cast<std::uint32_t>(trace_publish_1 - trace_publish_0), .extra = static_cast<std::uint32_t>(trace_publish_2 - trace_publish_1), "
                      ".mask = static_cast<std::uint32_t>(trace_publish_3 - trace_publish_2), .queue = static_cast<std::uint32_t>(trace_publish_4 - trace_publish_3), "
                      ".kind = queue_trace::Kind::publish, .frames = static_cast<std::uint32_t>(trace_publish_5 - trace_publish_4)});\n")
            replace_once(path, anchor, line + record + "\n" + anchor)
        else:
            replace_once(path, anchor, line + anchor)


def stop_edits(path, handler, indentation, loop, finish):
    replace_once(path, handler, handler.replace("model_.stopping = true;", "queue_trace::record({.first = queue_trace::now(), .kind = queue_trace::Kind::stop_request});\n" + indentation + "model_.stopping = true;"))
    traced = loop.replace("      try {\n        client->connection.send(RuntimeStopping{});\n", "      client->connection.traceSnapshot(0);\n\n      try {\n        client->connection.send(RuntimeStopping{});\n        client->connection.traceSnapshot(1);\n")
    traced = traced.replace("      dropClient(", "      client->connection.traceSnapshot(2);\n      dropClient(")
    replace_once(path, loop, traced)
    replace_once(path, finish, finish[:finish.rindex("\n")] + "\n" + indentation + "queue_trace::flush();" + finish[finish.rindex("\n"):])


def header_tree(root):
    runtime = root / "services/runtime-cpp"
    frames = runtime / "transport/outgoing_frames.hpp"
    connection = runtime / "transport/connection.hpp"
    runtime_hpp = runtime / "runtime/runtime.hpp"
    if "QUEUE_TRACE_INLINE" in frames.read_text():
        raise SystemExit(f"{frames} is already instrumented")

    replace_once(frames, "#include <exception>\n\nnamespace telar::runtime {\n", "#include <exception>\n#include <algorithm>\n#include <atomic>\n#include <chrono>\n#include <cstdio>\n#include <cstdlib>\n#include <vector>\n#include <fcntl.h>\n#include <sys/mman.h>\n#include <unistd.h>\n\n#define QUEUE_TRACE_INLINE inline\n" + snippet("trace_api.inc") + snippet("trace_impl.inc") + "\nnamespace telar::runtime {\n")
    replace_once(frames, """      bytes_.truncate(previous_size);
      throw;
    }

    inserted(lane);
  }""", """      bytes_.truncate(previous_size);
      throw;
    }

    inserted(lane);
    traceAppend(frame_prefix_size + size, lane);
  }""")
    replace_once(frames, """    deferred_.append(bytes_.size(), request);
    inserted(DeliveryLane::management);
  }""", """    deferred_.append(bytes_.size(), request);
    inserted(DeliveryLane::management);
    traceDefer();
  }""")
    replace_once(frames, """    deferred_.resolved(resolved_size);
  }""", """    deferred_.resolved(resolved_size);
    traceInsert(offset, resolved_size, DeliveryLane::management);
  }""")
    frames_edits(frames, "  ")
    replace_once(frames, """  void clear() noexcept {
    bytes_.clear();""", """  void clear() noexcept {
    traceCleared();
    bytes_.clear();""")
    replace_once(frames, """    active_offset_ = offset;
    active_remaining_ = frame.size;
  }""", """    active_offset_ = offset;
    active_remaining_ = frame.size;
    trace_active_lane_ = frame.lane;
  }""")
    replace_once(frames, """  std::uint64_t dropped() const noexcept { return dropped_; }

private:
""", """  std::uint64_t dropped() const noexcept { return dropped_; }

""" + snippet("trace_declarations.inc") + """
private:
""")
    replace_once(frames, """  std::size_t prepared_size_ = 0;
};

}""", """  std::size_t prepared_size_ = 0;
""" + snippet("trace_state.inc") + """};

""" + indent(snippet("trace_members.inc"), "") + """
}""")

    replace_once(connection, """    const auto count = ::write(descriptor_.get(), bytes.data(), bytes.size());
    if (count > 0) {
      output_.consume(static_cast<std::size_t>(count));
      return;
    }

    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {""", """    const auto started = queue_trace::now();
    const auto count = ::write(descriptor_.get(), bytes.data(), bytes.size());
    const int error = count < 0 ? errno : 0;

    output_.traceWrite(started, bytes.size(), count, error);
    if (count > 0) {
      output_.consume(static_cast<std::size_t>(count));
      return;
    }

    if (count < 0 && (error == EAGAIN || error == EWOULDBLOCK || error == EINTR)) {""")
    replace_once(connection, "  bool negotiated = false;", """  void traceSnapshot(std::uint16_t phase) const noexcept {
    output_.traceSnapshot(phase);
  }

  bool negotiated = false;""")

    stop_edits(runtime_hpp, "  void handle(ClientSession<Memory> &, const RuntimeStop &) {\n    model_.stopping = true;", "    ", """      try {
        client->connection.send(RuntimeStopping{});
        client->connection.write(ResponseProjection{memory_, model_});
      } catch (...) {
      }

      dropClient(client->id);
""", """    observations_.finish();
    media_.finish();
  }""")

    publish_edits(runtime_hpp, "    TELAR_TRACE(\"runtime.publish\");",
                  "    for (auto *pane : model_.panes.items()) {\n      if (pane != nullptr) {\n        try {\n          if (ClipboardService{model_}.advance(",
                  "    if (executions_.refresh()) {", "    try {\n      observations_.refresh();",
                  "    worktrees_.refresh();", "    for (auto *client : model_.clients.items()) {\n      if (client == nullptr) {\n        continue;\n      }\n\n      if (client->connection.closing && !client->connection.hasOutput()) {")

    tests = runtime / "cmake/tests.cmake"
    replace_once(tests, "add_executable(checkpoint-probe tests/checkpoint_probe.cpp)\n", f"add_executable(checkpoint-probe tests/checkpoint_probe.cpp)\nadd_executable(pane-traffic-probe \"{HERE / 'pane_traffic_probe.cpp'}\")\ntarget_include_directories(pane-traffic-probe PRIVATE \"${{CMAKE_CURRENT_SOURCE_DIR}}/tests\")\ntarget_compile_definitions(pane-traffic-probe PRIVATE QUEUE_TRACE_HEADERS=1)\ntarget_link_libraries(pane-traffic-probe PRIVATE runtime-core)\n")
    return runtime


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("root", type=Path, help="root of a disposable worktree")
    root = parser.parse_args().root.resolve()
    if (root / "src/runtime/transport/connection/connection.cppm").exists():
        print(module_tree(root))
    elif (root / "services/runtime-cpp/transport/outgoing_frames.hpp").exists():
        print(header_tree(root))
    else:
        raise SystemExit(f"{root}: no runtime tree this tool knows")


if __name__ == "__main__":
    main()

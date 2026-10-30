#pragma once

#include "../agents/reporter_state.hpp"
#include "../agents/resume.hpp"
#include "../diagnostics/runtime_counters.hpp"
#include "../graphics/pane_media.hpp"
#include "../memory/byte_queue.hpp"
#include "../observation/pane_observer.hpp"
#include "../persistence/launch_record.hpp"
#include "../platform/command.hpp"
#include "../platform/process_cache.hpp"
#include "../terminal/terminal.hpp"
#include "pane_launch.hpp"
#include <chrono>
#include <csignal>
#include <sys/wait.h>
#include <sys/uio.h>
#include <system_error>

namespace telar::runtime {

template <Allocator Memory>
class Pane {
  struct ResponseWriter {
    ssize_t operator()(int descriptor, std::span<const iovec> vectors) const {
      return ::writev(descriptor, vectors.data(), static_cast<int>(vectors.size()));
    }
  };

public:
  enum class ReadMode {
    once,
    burst
  };

  explicit Pane(Memory &memory, std::uint64_t identity, TabLocation location, Command<Memory> &command, PaneLaunch settings)
      : id(identity),
        location(location),
        launch(memory),
        pty_responses(std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, Memory>{memory})),
        observer(std::allocate_shared<PaneObserver<Memory>>(AllocatorRef<PaneObserver<Memory>, Memory>{memory}, memory, settings.size, command.cwd())),
        media(std::allocate_shared<PaneMedia<Memory>>(AllocatorRef<PaneMedia<Memory>, Memory>{memory}, memory, settings.media_budget, settings.graphics, settings.size, pty_responses)),
        terminal(memory, settings.size, TerminalPurpose::separate_media, pty_responses, GraphicsQueryResources{settings.graphics, settings.media_budget, &media->queryUsage()}),
        input(memory, input_limit),
        cwd(command.cwd(), AllocatorRef<char, Memory>{memory}) {
    ::arc4random_buf(history_session.data(), history_session.size());
    input.reserve(input_limit);
    launch.capture(command.arguments(), command.restorable());
    const auto executable = std::string_view{command.arguments().front()};
    foreground.assign(utf8Prefix(executable.substr(executable.rfind('/') + 1), 48));
    process.emplace(command.specification(settings.size));
    terminal.attachMedia(*media);
  }

  bool read(ReadMode mode = ReadMode::once) {
    constexpr std::size_t batch_byte_limit = 64 * 1024;
    constexpr unsigned batch_read_limit = 8;
    std::array<Byte, read_buffer_size> buffer;
    std::size_t batch_bytes = 0;
    const unsigned read_limit = mode == ReadMode::burst ? batch_read_limit : 1;
    for (unsigned attempt = 0; attempt < read_limit && batch_bytes < batch_byte_limit; ++attempt) {
      const auto capacity = std::min(buffer.size(), batch_byte_limit - batch_bytes);
      if (terminal.hasPendingControl() || media->holdsRead(capacity)) {
        TELAR_DIAGNOSTIC(media->noteHeldRead());
        return true;
      }

      const auto count = ::read(process->descriptor(), buffer.data(), capacity);
      if (count > 0) {
        const auto bytes = std::span<const Byte>{buffer}.first(static_cast<std::size_t>(count));
        TELAR_DIAGNOSTIC(recordRead(bytes.size(), batch_bytes != 0));
        const auto foreground = needs_foreground_observation ? shellForeground() : std::nullopt;
        expireProgress(foreground);
        observer->bytes(ObservationKind::output, bytes, foreground);
        {
          TELAR_DIAGNOSTIC(diagnostics::TimedScope timing{counters == nullptr ? nullptr : &counters->ingest});
          terminal.feed(bytes);
        }
        batch_bytes += bytes.size();
        continue;
      }

      if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
        return true;
      }

      output_closed = true;
      terminal.abortControl();
      return false;
    }

    return true;
  }

  // The response writer borrows vectors only for this call. Only a positive
  // syscall result consumes the admitted prefix; EINTR/EAGAIN retain it.
  template <typename WriteResponses = ResponseWriter>
  void write(WriteResponses write_responses = {}) {
    const auto batch = pty_responses->peekBatch();
    const bool response = batch.count != 0;
    const auto bytes = input.readable();
    if (response && batch.bytes == 0) {
      pty_responses->consumeBytes(0);
      terminal.resumeControl();
      return;
    }
    if (!response && bytes.empty()) {
      return;
    }

    const auto count = [&] {
      TELAR_DIAGNOSTIC(diagnostics::TimedScope timing{counters == nullptr ? nullptr : &counters->input_write});
      if (response) {
        std::array<iovec, PtyResponseQueue::message_capacity> vectors;
        for (std::size_t index = 0; index < batch.count; ++index) {
          const auto message = batch.message(index);
          vectors[index] = {const_cast<Byte *>(message.data()), message.size()};
        }
        return write_responses(process->descriptor(), std::span<const iovec>{vectors}.first(batch.count));
      }
      return ::write(process->descriptor(), bytes.data(), bytes.size());
    }();
    if (count > 0) {
      if (response) {
        pty_responses->consumeBytes(static_cast<std::size_t>(count));
        terminal.resumeControl();
      } else {
        input.consume(static_cast<std::size_t>(count));
      }

      return;
    }

    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
      return;
    }

    input.clear();
    pty_responses->clear();
    throw std::system_error{count < 0 ? errno : EIO, std::generic_category(), "PTY write failed"};
  }

  bool hasInput() const noexcept {
    return !input.empty() || !pty_responses->empty();
  }

  void requestClose() noexcept {
    if (close_requested) {
      return;
    }

    close_requested = true;
    process->shutdown();
  }

  void enqueueInput(std::span<const Byte> bytes) {
    input.append(bytes);
    TELAR_DIAGNOSTIC(if (counters != nullptr) {
      diagnostics::accumulate(counters->input_events);
      diagnostics::accumulate(counters->input_bytes, bytes.size());
    });
    observer->bytes(ObservationKind::input, bytes, shellForeground());
    ++input_revision;
    needs_foreground_observation = true;
  }

  void resize(TerminalSize size) {
    if (terminal.hasSize(size)) {
      return;
    }

    terminal.resize(size);
    process->resize(size);
    observer->resize(size);
    media->resize(size);
  }

  std::optional<bool> shellForeground() const noexcept {
    if (shell_markers) {
      return std::nullopt;
    }

    const auto foreground = process->foregroundProcessGroup();
    return foreground ? std::optional<bool>{*foreground == process->processId()} : std::nullopt;
  }

  std::optional<std::int32_t> exitCode() const noexcept {
    if (!exit_status) {
      return std::nullopt;
    }

    if (WIFEXITED(*exit_status)) {
      return WEXITSTATUS(*exit_status);
    }

    constexpr int signal_exit_offset = 128;
    return signal_exit_offset + WTERMSIG(*exit_status);
  }

  static constexpr std::size_t input_limit = 128 * 1024;
  static constexpr std::size_t read_buffer_size = 16 * 1024;
#if TELAR_DIAGNOSTICS
  diagnostics::PaneCounters *counters = nullptr;
  std::uint64_t input_dropped_bytes = 0;
#endif
  std::uint64_t id;
  std::uint64_t event_identity = 0;
  std::optional<ConfigurePaneDesktop> desktop_theme;
  std::uint64_t generation = 1;
  std::array<Byte, 16> history_session;
  TabLocation location;
  LaunchRecord<Memory> launch;
  std::optional<AgentResume> restored_agent;
  std::shared_ptr<PtyResponseQueue> pty_responses;
  std::shared_ptr<PaneObserver<Memory>> observer;
  std::shared_ptr<PaneMedia<Memory>> media;
  Terminal<Memory> terminal;
  ByteQueue<Memory> input;
  String<Memory> cwd;
  std::optional<PtyProcess> process;
  std::uint32_t observers = 0;
  std::uint64_t cwd_revision = 0;
  std::optional<std::uint64_t> worktree_checked_cwd;
  std::uint64_t input_revision = 0;
  FixedText<48> foreground;
  std::uint64_t foreground_revision = 1;
  bool output_closed = false;
  bool exit_published = false;
  bool exit_observed = false;
  bool shell_markers = false;
  bool needs_foreground_observation = false;
  bool write_interest = false;
  bool read_paused = false;
  std::optional<int> exit_status;
  std::chrono::steady_clock::time_point sync_started{};
  std::optional<std::chrono::steady_clock::time_point> last_input;
  bool close_requested = false;
  ProcessCache process_cache;
  std::uint32_t process_rechecks = 0;
  bool process_recheck_requested = false;
  bool process_recheck_running = false;
  std::optional<RejectedReporter> rejected_reporter;

private:
  void expireProgress(std::optional<bool> shell_foreground) noexcept {
    if (terminal.effects.progress_state == PaneProgressState::remove) {
      return;
    }

    if (!shell_foreground) {
      const auto group = process->foregroundProcessGroup();
      shell_foreground = group && *group == process->processId();
    }
    if (*shell_foreground) {
      terminal.effects.setProgress(PaneProgressState::remove, std::nullopt);
    }
  }

#if TELAR_DIAGNOSTICS
  void recordRead(std::size_t size, bool folded) noexcept {
    if (counters == nullptr) {
      return;
    }

    diagnostics::accumulate(counters->pty_events);
    diagnostics::accumulate(counters->pty_bytes, size);
    diagnostics::accumulate(counters->folded_pty_events, folded);
  }
#endif
};

}

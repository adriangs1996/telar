#pragma once

#include "../diagnostics/trace.hpp"
#include "frame_channel.hpp"
#include "pipe_stream.hpp"
#include "result.hpp"
#include "session_io.hpp"
#include <csignal>
#include <cstdio>
#include <thread>

namespace telar::runtime::plugins {

struct SessionOptions {
  const char *executable;
  const char *entry;
  const CancellationSignal &cancellation;
  std::chrono::milliseconds timeout = Limits::reply_deadline;
  const char *trace_path = nullptr;
  bool traffic = false;
};

template <Allocator Memory>
class Session {
public:
  explicit Session(Memory &memory, const SessionOptions &options)
      : memory_(memory), process_(spawn(options)), stream_(process_.output(), process_.input(), SessionIo{process_, options.cancellation}), channel_(stream_), timeout_(options.timeout), tracing_(options.trace_path != nullptr) {}

  ~Session() {
#if TELAR_DEBUG
    if (tracing_) {
      finishTrace();
    }
#endif
    process_.signal(SIGKILL);
    stream_.wait().drainError();
    const auto error = stream_.wait().retainedError();
    if (!error.empty()) {
      std::fputs("tap worker stderr: ", stderr);
      std::fwrite(error.data(), 1, error.size(), stderr);
      std::fputc('\n', stderr);
    }
  }

  Session(const Session &) = delete;
  Session &operator=(const Session &) = delete;

  OwnedResult<Memory> exchange(const ServiceSpec &specification, std::uint64_t event_id, std::span<const Byte> frame) {
    TELAR_TRACE("plugins.workerExchange");
    auto received = request(frame, Limits::effect_bytes);

    const auto bytes = received.bytes();
    if (bytes.front() == static_cast<Byte>(FrameKind::error)) {
      const auto failure = Protocol::decodeError(bytes);
      requireEvent(event_id, failure.event_id);
      return {nullptr, AllocationDeleter<Result<Memory>, Memory>{memory_}};
    }
    const auto reply = Protocol::decodeEffects(bytes);
    requireEvent(event_id, reply.event_id);
    return makeOwned<Result<Memory>>(memory_, specification, std::move(received), reply);
  }

  SensitiveAllocation<Memory> request(std::span<const Byte> frame, std::size_t maximum_bytes) {
    stream_.wait().deadline(timeout_);
    channel_.send(frame);
    stream_.wait().deadline(timeout_);
    auto received = channel_.receive(memory_, maximum_bytes);
    if (!received) { throw SystemError{"Tap worker closed", EPIPE}; }
    if (!stream_.wait().active()) { throw SystemError{"Tap worker request cancelled or expired"}; }
    return std::move(*received);
  }

  std::string_view retainedError() const noexcept { return stream_.wait().retainedError(); }
  pid_t processId() const noexcept { return process_.processId(); }
  int outputDescriptor() const noexcept { return process_.output(); }

private:
  static PipeProcess spawn(const SessionOptions &options) {
    std::array<char *, 8> arguments{const_cast<char *>(options.executable), const_cast<char *>("tap-worker"), const_cast<char *>(options.entry), nullptr};
    std::size_t count = 3;
    if (options.traffic) { arguments[count++] = const_cast<char *>("--traffic"); }
#if TELAR_DEBUG
    if (options.trace_path != nullptr) {
      arguments[count++] = const_cast<char *>("--trace");
      arguments[count++] = const_cast<char *>(options.trace_path);
    }
#endif
    std::array<char *, 1> environment{nullptr};
    return PipeProcess{SpawnSpec{.executable = options.executable, .cwd = "/", .arguments = arguments.data(), .environment = environment.data(), .size = {}}, ProcessInput::buffered_socket};
  }

  static void requireEvent(std::uint64_t expected, std::uint64_t received) {
    if (expected != received) {
      throw EncodingError{"Stale tap worker reply"};
    }
  }

#if TELAR_DEBUG
  void finishTrace() noexcept {
    process_.closeInput();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds{100};
    while (!process_.reap() && std::chrono::steady_clock::now() < deadline) {
      stream_.wait().drainError();
      std::this_thread::sleep_for(std::chrono::milliseconds{1});
    }
  }
#endif

  Memory &memory_;
  PipeProcess process_;
  PipeStream<SessionIo> stream_;
  FrameChannel<PipeStream<SessionIo>> channel_;
  std::chrono::milliseconds timeout_;
  [[maybe_unused]] bool tracing_;
};

}

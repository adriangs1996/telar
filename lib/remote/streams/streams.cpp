module telar.remote.streams;

import telar.base.ds;
import telar.platform.net;
import telar.sys.posix;

namespace telar::remote {

  namespace {

    // What a frame carries. Each starts with its kind, its stream and the length of its payload.
    enum class Kind : std::uint8_t {
      data = 0,
      end = 1,
      exit = 2,
    };

    enum class Stream : std::uint8_t {
      input = 0,
      output = 1,
      error = 2,
    };

    constexpr std::size_t stream_count = 3;
    constexpr std::size_t header_bytes = 4;
    constexpr std::size_t payload_bytes = 16000;
    constexpr std::size_t frame_bytes = header_bytes + payload_bytes;
    constexpr std::size_t buffer_bytes = 2 * frame_bytes;
    constexpr std::size_t request_bytes = 9;
    constexpr unsigned byte_bits = 8;
    constexpr unsigned byte_mask = 0xff;

    // A command whose streams ended is about to exit: its status is asked for again after a
    // wait that starts at a millisecond and doubles up to this one, so that a quick command is
    // not held for a tick and a slow one is not polled in a loop.
    constexpr int longest_reap_wait_ms = 20;

    void putU16(std::span<std::uint8_t> output, std::uint16_t value) noexcept {
      output[0] = static_cast<std::uint8_t>(value >> byte_bits);
      output[1] = static_cast<std::uint8_t>(value & byte_mask);
    }

    std::uint16_t getU16(std::span<const std::uint8_t> input) noexcept {
      return static_cast<std::uint16_t>((static_cast<unsigned>(input[0]) << byte_bits) | input[1]);
    }

    void putU32(std::span<std::uint8_t> output, std::uint32_t value) noexcept {
      putU16(output, static_cast<std::uint16_t>(value >> (2 * byte_bits)));
      putU16(output.subspan(2), static_cast<std::uint16_t>(value & 0xffffU));
    }

    std::uint32_t getU32(std::span<const std::uint8_t> input) noexcept {
      return (static_cast<std::uint32_t>(getU16(input)) << (2 * byte_bits)) | getU16(input.subspan(2));
    }

    // A descriptor this end reads to send a stream.
    struct Source {
      int descriptor = -1;
      Stream stream = Stream::input;
      bool ended = true;
      // poll said it can be read, which is asked before every read: the descriptor may block.
      bool ready = false;
    };

    // A descriptor this end writes a received stream to.
    struct Sink {
      int descriptor = -1;
      bool open = false;
      // A sink of this process's own is written without waiting; a borrowed one is left blocking.
      bool nonblocking = false;
    };

    // What the server's side asks of the command it runs.
    struct Process {
      void* context = nullptr;
      ds::Option<int> (*reap)(void* context) noexcept = nullptr;
      void (*closeInput)(void* context) noexcept = nullptr;
    };

    // A buffer whose bytes leave from the front and arrive at the back.
    struct Queue {
      ds::Array<std::uint8_t, buffer_bytes> bytes;
      std::size_t begin = 0;
      std::size_t end = 0;

      [[nodiscard]] std::size_t size() const noexcept {
        return end - begin;
      }

      [[nodiscard]] std::span<const std::uint8_t> view() const noexcept {
        return bytes.view().subspan(begin, size());
      }

      // The room at the back, after moving what is left to the front when that frees any.
      [[nodiscard]] std::span<std::uint8_t> room() noexcept {
        if (begin == end) {
          begin = 0;
          end = 0;
        } else if (begin != 0 && bytes.size() - end < frame_bytes) {
          std::memmove(bytes.dataMut(), bytes.data() + begin, size());
          end -= begin;
          begin = 0;
        }

        return bytes.viewMut().subspan(end);
      }
    };

    class Pump {
    public:
      explicit Pump(Channel& channel) noexcept
          : channel_(channel) {}

      void read(int descriptor, Stream stream) noexcept {
        sources_.atMut(source_count_++) = {.descriptor = descriptor, .stream = stream, .ended = false};
      }

      void write(Stream stream, int descriptor, bool nonblocking) noexcept {
        sinks_.atMut(static_cast<std::size_t>(stream)) = {.descriptor = descriptor, .open = true, .nonblocking = nonblocking};
      }

      // The client's side: until the command's status comes, or the connection is lost.
      [[nodiscard]] int client() noexcept {
        while (!status_ && !failed_ && !peer_ended_) {
          step(-1);
        }

        return status_.valueOr(connection_lost_status);
      }

      // The server's side: until the command exited and the client was told, or the client left.
      void server(const Process& process) noexcept {
        process_ = &process;
        int reap_wait_ms = 1;

        while (!failed_ && !peer_ended_ && !told_) {
          bool waiting = sourcesEnded() && !exit_queued_;

          if (waiting) {
            queueExit();
            waiting = !exit_queued_;
          }

          step(waiting ? reap_wait_ms : -1);
          if (waiting) {
            reap_wait_ms = std::min(2 * reap_wait_ms, longest_reap_wait_ms);
          }

          if (exit_queued_ && outgoing_.size() == 0) {
            told_ = channel_.finish().state != Transfer::State::wants_write;
          }
        }
      }

    private:
      [[nodiscard]] bool sourcesEnded() const noexcept {
        return std::ranges::all_of(std::span{sources_}.first(source_count_), &Source::ended);
      }

      void queueExit() noexcept {
        const auto status = process_->reap(process_->context);
        if (!status || outgoing_.room().size() < header_bytes + sizeof(std::uint32_t)) {
          return;
        }

        auto frame = outgoing_.room();

        frame[0] = static_cast<std::uint8_t>(Kind::exit);
        frame[1] = 0;
        putU16(frame.subspan(2), sizeof(std::uint32_t));
        putU32(frame.subspan(header_bytes), static_cast<std::uint32_t>(runtime::shellExitCode(*status)));
        outgoing_.end += header_bytes + sizeof(std::uint32_t);
        exit_queued_ = true;
      }

      // Moves everything that can move, then waits for what cannot.
      void step(int timeout) noexcept {
        bool moved = false;

        interest_ = 0;
        blocked_sink_ = -1;
        moved = receive() || moved;
        moved = deliver() || moved;
        moved = collect() || moved;
        moved = flush() || moved;
        if (!moved && !failed_) {
          wait(timeout);
        }
      }

      // Reads frames from the channel while there is room for a whole one.
      bool receive() noexcept {
        if (peer_ended_ || incoming_.room().size() < frame_bytes) {
          return false;
        }

        const auto taken = channel_.read(incoming_.room());
        if (taken.state == Transfer::State::done) {
          incoming_.end += taken.bytes;
          return true;
        }

        note(taken.state);
        peer_ended_ = taken.state == Transfer::State::ended;
        return false;
      }

      // Hands the complete frames received to their sinks, in order.
      bool deliver() noexcept {
        bool moved = false;

        while (incoming_.size() >= header_bytes) {
          const auto frame = incoming_.view();
          const std::size_t length = getU16(frame.subspan(2));
          if (length > payload_bytes || frame[1] >= stream_count || frame[0] > static_cast<std::uint8_t>(Kind::exit)) {
            failed_ = true;
            return moved;
          }

          if (frame.size() < header_bytes + length) {
            break;
          }

          const auto payload = frame.subspan(header_bytes, length);
          const auto kind = static_cast<Kind>(frame[0]);
          if (kind == Kind::data && !pour(sinks_.atMut(frame[1]), payload)) {
            break;
          }

          if (kind == Kind::end) {
            finishSink(frame[1]);
          } else if (kind == Kind::exit && length == sizeof(std::uint32_t)) {
            status_ = static_cast<int>(getU32(payload));
          }

          incoming_.begin += header_bytes + length;
          delivered_ = 0;
          moved = true;
        }

        return moved;
      }

      // Writes a payload to its sink; false while part of it still waits for the sink.
      bool pour(Sink& sink, std::span<const std::uint8_t> payload) noexcept {
        while (sink.open && delivered_ < payload.size()) {
          const auto rest = payload.subspan(delivered_);
          const auto written = ::write(sink.descriptor, rest.data(), rest.size());
          if (written > 0) {
            delivered_ += static_cast<std::size_t>(written);
          } else if (sys::lastError() == EINTR) {
            continue;
          } else if (sink.nonblocking && runtime::socketWouldBlock(sys::lastError())) {
            blocked_sink_ = sink.descriptor;
            return false;
          } else {
            // Its reader is gone: what remains for it is dropped, as a closed pipe drops it.
            sink.open = false;
          }
        }

        return true;
      }

      void finishSink(std::uint8_t stream) noexcept {
        sinks_.atMut(stream).open = false;
        if (process_ != nullptr && stream == static_cast<std::uint8_t>(Stream::input)) {
          process_->closeInput(process_->context);
        }
      }

      // Frames what the sources have to send while a whole frame fits.
      bool collect() noexcept {
        bool moved = false;

        for (auto& source : sources_.viewMut().first(source_count_)) {
          auto room = outgoing_.room();
          if (source.ended || !source.ready || room.size() < frame_bytes) {
            continue;
          }

          const auto count = ::read(source.descriptor, room.data() + header_bytes, payload_bytes);

          source.ready = false;
          if (count < 0 && (sys::lastError() == EINTR || runtime::socketWouldBlock(sys::lastError()))) {
            continue;
          }

          // A terminal whose command left fails its reads, which ends the stream like an end of file.
          source.ended = count <= 0;
          room[0] = static_cast<std::uint8_t>(source.ended ? Kind::end : Kind::data);
          room[1] = static_cast<std::uint8_t>(source.stream);
          putU16(room.subspan(2), source.ended ? 0 : static_cast<std::uint16_t>(count));
          outgoing_.end += header_bytes + (source.ended ? 0 : static_cast<std::size_t>(count));
          moved = true;
        }

        return moved;
      }

      bool flush() noexcept {
        if (outgoing_.size() == 0) {
          return false;
        }

        const auto written = channel_.write(outgoing_.view());
        if (written.state == Transfer::State::done) {
          outgoing_.begin += written.bytes;
          return true;
        }

        note(written.state);
        failed_ = failed_ || written.state == Transfer::State::ended;
        return false;
      }

      void note(Transfer::State state) noexcept {
        if (state == Transfer::State::wants_read) {
          interest_ = static_cast<short>(interest_ | POLLIN);
        } else if (state == Transfer::State::wants_write) {
          interest_ = static_cast<short>(interest_ | POLLOUT);
        } else if (state == Transfer::State::failed) {
          failed_ = true;
        }
      }

      void wait(int timeout) noexcept {
        ds::Array<pollfd, 2 + stream_count> entries{};
        std::size_t count = 0;

        entries.atMut(count++) = {.fd = channel_.descriptor(), .events = interest_, .revents = 0};
        if (blocked_sink_ >= 0) {
          entries.atMut(count++) = {.fd = blocked_sink_, .events = POLLOUT, .revents = 0};
        }

        const auto first_source = count;
        const bool room = outgoing_.room().size() >= frame_bytes;

        for (const auto& source : std::span{sources_}.first(source_count_)) {
          entries.atMut(count++) = {.fd = source.ended || !room ? -1 : source.descriptor, .events = POLLIN, .revents = 0};
        }

        if (::poll(entries.dataMut(), static_cast<nfds_t>(count), timeout) < 0) {
          failed_ = sys::lastError() != EINTR;
          return;
        }

        for (std::size_t index = 0; index < source_count_; ++index) {
          sources_.atMut(index).ready = entries[first_source + index].revents != 0;
        }
      }

      Channel& channel_;
      const Process* process_ = nullptr;
      ds::Array<Source, 2> sources_{};
      std::size_t source_count_ = 0;
      ds::Array<Sink, stream_count> sinks_{};
      Queue incoming_;
      Queue outgoing_;
      // The bytes of the first received frame's payload its sink already took.
      std::size_t delivered_ = 0;
      ds::Option<int> status_;
      int blocked_sink_ = -1;
      short interest_ = 0;
      bool peer_ended_ = false;
      bool failed_ = false;
      bool exit_queued_ = false;
      bool told_ = false;
    };

    ds::Option<int> reapPipes(void* context) noexcept {
      return static_cast<runtime::PipeProcess*>(context)->reap();
    }

    void closePipeInput(void* context) noexcept {
      static_cast<runtime::PipeProcess*>(context)->closeInput();
    }

    ds::Option<int> reapTerminal(void* context) noexcept {
      return static_cast<runtime::PtyProcess*>(context)->reap();
    }

    // A terminal has no end of input to pass on: its command reads the terminal until it exits.
    void keepTerminalInput(void* /*context*/) noexcept {}

  }

  void sendRunRequest(Channel& channel, const RunRequest& request, std::string_view command) {
    ds::Array<std::uint8_t, request_bytes> header{};
    const auto deadline = Clock::now() + exchange_timeout;

    if (command.size() > RunRequest::maximum_command_bytes) {
      throw ChannelFailure{"The command is longer than a gateway runs"};
    }

    header.atMut(0) = request.terminal ? 1 : 0;
    putU16(header.viewMut().subspan(1), request.rows);
    putU16(header.viewMut().subspan(3), request.columns);
    putU32(header.viewMut().subspan(5), static_cast<std::uint32_t>(command.size()));
    channel.send(header.view(), deadline);
    channel.send({reinterpret_cast<const std::uint8_t*>(command.data()), command.size()}, deadline); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the command is sent as its bytes
  }

  std::string_view receiveRunRequest(Channel& channel, RunRequest& request, std::span<char> command) {
    ds::Array<std::uint8_t, request_bytes> header{};
    const auto deadline = Clock::now() + exchange_timeout;

    channel.receive(header.viewMut(), deadline);
    const std::size_t length = getU32(header.view().subspan(5));
    if (length == 0 || length > command.size()) {
      throw ChannelFailure{"The client asked to run a command longer than a gateway runs"};
    }

    request.terminal = header[0] != 0;
    request.rows = getU16(header.view().subspan(1));
    request.columns = getU16(header.view().subspan(3));
    channel.receive({reinterpret_cast<std::uint8_t*>(command.data()), length}, deadline); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the command is received as its bytes
    return {command.data(), length};
  }

  int pumpClient(Channel& channel, LocalStreams streams) noexcept {
    Pump pump{channel};

    pump.read(streams.input, Stream::input);
    pump.write(Stream::output, streams.output, false);
    pump.write(Stream::error, streams.error, false);
    return pump.client();
  }

  void pumpPipes(Channel& channel, runtime::PipeProcess& process) noexcept {
    Pump pump{channel};

    pump.read(process.output(), Stream::output);
    pump.read(process.error(), Stream::error);
    pump.write(Stream::input, process.input(), true);
    pump.server({.context = &process, .reap = &reapPipes, .closeInput = &closePipeInput});
  }

  void pumpTerminal(Channel& channel, runtime::PtyProcess& process) noexcept {
    Pump pump{channel};

    pump.read(process.descriptor(), Stream::output);
    pump.write(Stream::input, process.descriptor(), true);
    pump.server({.context = &process, .reap = &reapTerminal, .closeInput = &keepTerminalInput});
  }

}

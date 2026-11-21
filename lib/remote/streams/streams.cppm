export module telar.remote.streams;

// A command's standard streams and its exit status over one channel, as the run service carries
// them: frames of a stream's bytes each way, the end of a stream, and at last how it exited.
import std;

import telar.platform.process;
import telar.tbc;
import telar.remote.channel;

// Interface: telar_remote/run_request.cppm
export {
  namespace telar::remote {

    // What a client asks to run: a line for the account's shell, with a terminal of a size or
    // with plain pipes.
    struct RunRequest {
      static constexpr std::size_t maximum_command_bytes = std::size_t{256} * 1024;

      bool terminal = false;
      std::uint16_t rows = 24;
      std::uint16_t columns = 80;
    };

    // The exit status a client reports when the connection broke before the command's own came.
    inline constexpr int connection_lost_status = 255;

    void sendRunRequest(Channel& channel, const RunRequest& request, std::string_view command);

    // How long a gateway waits for a request to start: a client keeps a connection ready for
    // its next command for less than this, so that the command spends no time connecting.
    inline constexpr auto run_patience = std::chrono::seconds{30};
    inline constexpr auto ready_lifetime = std::chrono::seconds{20};

    // Reads a request and its command into `command`, and returns the command's text there.
    // Throws ChannelFailure for a command longer than `command`.
    [[nodiscard]] tbc::val_a<std::string_view> receiveRunRequest(Channel& channel, RunRequest& request, tbc::val_a<std::span<char>> command);

  }
}

// Interface: telar_remote/stream_pump.cppm
export {
  namespace telar::remote {

    // The descriptors a client's command reads and writes here. They are used as they are, never
    // made nonblocking: the terminal or the pipe behind them belongs to other processes too.
    struct LocalStreams {
      int input = 0;
      int output = 1;
      int error = 2;
    };

    // Carries the client's side until the command ends there, and returns its exit status.
    [[nodiscard]] int pumpClient(Channel& channel, LocalStreams streams) noexcept;

    // Carries a command's pipes until it exits, then tells the client how. A client that leaves
    // first ends the command.
    void pumpPipes(Channel& channel, runtime::PipeProcess& process) noexcept;

    // The same for a command on a terminal, whose one stream carries output and errors alike.
    void pumpTerminal(Channel& channel, runtime::PtyProcess& process) noexcept;

  }
}

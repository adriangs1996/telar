#pragma once

#include "command_io.hpp"
#include "control_session.hpp"
#include "telar_platform/runtime_paths.hpp"

namespace telar::runtime::cli::runtime_clipboard {

struct Options {
  std::optional<std::string_view> socket;

  static Options parse(Arguments words) {
    if (words.empty() || std::string_view{words.front()} != "get") {
      throw std::invalid_argument{"UnknownClipboardAction"};
    }
    Options options;
    Cursor cursor{words.subspan(1)};
    while (const auto word = cursor.next()) {
      if (*word == "--socket" && !options.socket) {
        options.socket = cursor.take("MissingSocketPath");
      } else {
        throw std::invalid_argument{"UnknownClipboardOption"};
      }
    }
    return options;
  }
};

template <Allocator Memory>
int run(Memory &memory, const Options &options) {
  // Text may also contain terminal escape sequences. Reject before capturing.
  if (::isatty(STDOUT_FILENO)) {
    throw std::runtime_error{"Pipe clipboard content to a consumer or redirect stdout to a file"};
  }
  try {
    ServerOptions server_options{};
    server_options.socket = options.socket.value_or("");
    const RuntimePaths paths{memory, server_options, ProcessEnvironment{}};
    constexpr std::size_t frame_bytes = runtime_clipboard_chunk_bytes + 1024;
    ControlSession session{memory, paths.socket.c_str(), frame_bytes, 128};
    session.receiveTimeout(10);
    ReadRuntimeClipboard request;
    std::uint64_t total = 0;
    std::string mime;
    for (;;) {
      const auto chunk = session.template exchange<RuntimeClipboardChunk>(request);
      if (chunk.offset != request.offset) {
        throw std::runtime_error{"Clipboard chunk arrived out of sequence"};
      }
      if (request.transfer_id == 0) {
        request.transfer_id = chunk.transfer_id;
        total = chunk.total_bytes;
        mime = chunk.mime;
      } else if (chunk.transfer_id != request.transfer_id || chunk.total_bytes != total || chunk.mime != mime) {
        throw std::runtime_error{"Clipboard transfer metadata changed"};
      }
      writeBytes(STDOUT_FILENO, chunk.bytes);
      request.offset += chunk.bytes.size();
      if (request.offset == total) {
        return 0;
      }
    }
  } catch (const ControlFailure &error) {
    std::fprintf(stderr, "telar clipboard: %.*s\n", static_cast<int>(error.message().size()), error.message().data());
    return 1;
  }
}

}

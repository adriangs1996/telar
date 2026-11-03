#pragma once

#include "../platform/delimited_read.hpp"
#include "socket_stream.hpp"
#include "telar_base/memory/sensitive_buffer.hpp"

namespace telar::runtime {

class ConnectHead {
public:
  static constexpr std::size_t capacity = 16 * 1024;
  using Read = DelimitedRead::Result;

  Read receive(int socket) noexcept {
    SocketStream stream{socket};
    return reader_.receive(stream, storage_.bytes(), "\r\n\r\n");
  }

  std::string_view text() noexcept {
    return {reinterpret_cast<const char *>(storage_.bytes().data()), reader_.length()};
  }

  void erase() noexcept {
    eraseSensitive(storage_.bytes().data(), capacity);
    reader_.reset();
  }

private:
  SensitiveBuffer<capacity> storage_;
  DelimitedRead reader_;
};

}

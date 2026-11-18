#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.testing.test_memory;
import telar.platform.fs;
import telar.wire.runtime;
import telar.cli.control_session;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::cli;

  bool readExactly(int descriptor, char* bytes, std::size_t size) {
    while (size != 0) {
      const auto count = ::read(descriptor, bytes, size);
      if (count <= 0) {
        return false;
      }

      bytes += count;
      size -= static_cast<std::size_t>(count);
    }

    return true;
  }

  ds::Option<std::string> readFrame(int descriptor) {
    ds::Array<unsigned char, 4> prefix{};
    if (!readExactly(descriptor, reinterpret_cast<char*>(prefix.dataMut()), prefix.size())) {
      return ds::none;
    }

    std::string frame(prefix[0] | prefix[1] << 8 | prefix[2] << 16 | static_cast<std::size_t>(prefix[3]) << 24, '\0');

    return readExactly(descriptor, frame.data(), frame.size()) ? ds::Option{frame} : ds::none;
  }

  void writeFrame(int descriptor, std::string_view frame) {
    std::string bytes(4, '\0');

    for (std::size_t index = 0; index < 4; ++index) {
      bytes[index] = static_cast<char>(frame.size() >> (8 * index));
    }

    bytes += frame;
    check(::write(descriptor, bytes.data(), bytes.size()) == static_cast<ssize_t>(bytes.size()));
  }

  std::string requestId(std::uint64_t id) {
    std::string bytes(8, '\0');

    for (std::size_t index = 0; index < 8; ++index) {
      bytes[index] = static_cast<char>(id >> (8 * index));
    }

    return bytes;
  }

  // RequestCompleted, RequestFailed and RuntimeStopping as the runtime sends them.
  std::string completed(std::uint64_t id) {
    return "\xa1" + requestId(id);
  }

  std::string refused(std::uint64_t id) {
    return "\x84" + requestId(id) + std::string{"\x01\x00", 2} + "refused";
  }

  const std::string stopping = "\x85";

  // A runtime on a private socket: it answers the handshake, then, once it has read
  // `requests` frames, sends `replies` and holds the connection until the client leaves.
  class FakeRuntime {
  public:
    FakeRuntime(std::size_t requests, std::vector<std::string> replies)
        : directory_{"/tmp/telar-control-XXXXXX"},
          path_{std::string{directory_.path()} + "/runtime.sock"},
          listener_{::socket(AF_UNIX, SOCK_STREAM, 0)} {
      sockaddr_un address{};

      address.sun_family = AF_UNIX;
      std::strncpy(address.sun_path, path_.c_str(), sizeof(address.sun_path) - 1);
      check(listener_ >= 0 && ::bind(listener_, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0 && ::listen(listener_, 1) == 0);
      thread_ = std::thread{[this, requests, replies = std::move(replies)] {
        const int connection = ::accept(listener_, nullptr, nullptr);
        const auto hello = readFrame(connection);

        check(hello && hello->starts_with("TELARIPC\x01"));
        writeFrame(connection, "TELARIPC\x02" + hello->substr(9));
        for (std::size_t count = 0; count < requests; ++count) {
          check(readFrame(connection).hasValue());
        }

        for (const auto& reply : replies) {
          writeFrame(connection, reply);
        }

        while (readFrame(connection)) {
        }

        ::close(connection);
      }};
    }

    ~FakeRuntime() {
      thread_.join();
      ::close(listener_);
    }

    FakeRuntime(const FakeRuntime&) = delete;
    FakeRuntime& operator=(const FakeRuntime&) = delete;

    const char* path() const noexcept {
      return path_.c_str();
    }

  private:
    TemporaryDirectory directory_;
    std::string path_;
    int listener_;
    std::thread thread_;
  };

  // A reply or refusal for another request, as one left by a fire-and-forget send, is not
  // the answer: the exchange returns the reply that carries its own request id.
  void skipsRepliesForOtherRequests() {
    FakeRuntime runtime{2, {completed(1), refused(1), completed(2)}};
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;

    {
      ControlSession session{memory, runtime.path()};

      session.receiveTimeout(10);
      session.send(QueryLimits{});
      const auto reply = session.exchange<RequestCompleted>(QueryLimits{});

      check(reply.request_id == 2);
    }
  }

  // A runtime that stops ends the exchange at once with RuntimeStopping, rather than the
  // command waiting out its reply timeout.
  void stoppingRuntimeAbortsExchange() {
    FakeRuntime runtime{1, {stopping}};
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    std::string error;

    {
      ControlSession session{memory, runtime.path()};

      session.receiveTimeout(2);
      try {
        session.exchange<RequestCompleted>(QueryLimits{});
      } catch (const std::exception& thrown) {
        error = thrown.what();
      }
    }

    check(error == "RuntimeStopping", error);
  }

  const telar::testing::Case case_other_requests{"control_session.skips_replies_for_other_requests", skipsRepliesForOtherRequests};
  const telar::testing::Case case_stopping{"control_session.stopping_runtime_aborts_exchange", stoppingRuntimeAbortsExchange};

}

export module telar.remote.tests.fixture;

import std;
import telar.base.memory.allocators;
import telar.platform.fs;
import telar.platform.paths;
import telar.remote.identity;
import telar.tls;

export namespace telar::remote::tests {

  // The allocator OpenSSL takes its memory from in a test program, configured the first time a
  // test asks for it: the library accepts one configuration a process.
  ConcurrentMemory& tlsMemory() {
    static SystemAllocator system;
    static SynchronizedAllocator synchronized{system};
    static MemoryAdapter adapter{synchronized};
    static const runtime::TlsLibrary library{adapter};

    return adapter;
  }

  // An environment that names one state directory and nothing else.
  class StateEnvironment final : public runtime::EnvironmentSource {
  public:
    explicit StateEnvironment(std::string_view path) noexcept
        : path_(path) {}

    std::string_view lookup(const char* name) const override {
      return std::string_view{name} == "TELAR_GATEWAY_STATE" ? path_ : std::string_view{};
    }

  private:
    std::string_view path_;
  };

  // A gateway's state in a directory of its own, removed with it.
  struct Gateway {
    Gateway()
        : directory("/tmp/telar-remote-test.XXXXXX"),
          state(State::open(StateEnvironment{directory.path()})) {
      static_cast<void>(tlsMemory());
    }

    runtime::TemporaryDirectory directory;
    State state;
  };

}

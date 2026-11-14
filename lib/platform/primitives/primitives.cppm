module;
#include "telar_platform/graphics/child_shared_memory.hpp"
#include "telar_platform/mapped_region.hpp"

export module telar.platform.primitives;

import std;

// The descriptors, mappings and shared memory below are POSIX objects: their
// importers reach the system calls that operate on them from telar.sys.
import telar.sys.posix;

#if TELAR_DEBUG
import telar.base.memory.allocators;
#endif

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::runtime {
  using telar::runtime::copyGraphicsName;
  using telar::runtime::decodeGraphicsName;
  using telar::runtime::duplicateCloseOnExec;
  using telar::runtime::FileDescriptor;
  using telar::runtime::GraphicsChildSharedMemory;
  using telar::runtime::MappedRegion;
  using telar::runtime::setCloseOnExec;
  using telar::runtime::setNonblocking;
}

export namespace telar::runtime {

  // Fills `size` bytes at `data` from the kernel's random source, never
  // failing: arc4random_buf on macOS, getrandom on Linux, where musl has no
  // arc4random. A Linux that cannot answer getrandom aborts rather than hand
  // out predictable nonces.
  void randomBytes(void* data, std::size_t size) noexcept;

}

// The trace sink is defined in src/trace.cpp, a translation unit outside the module, so its
// declarations belong to the global module.
#if TELAR_DEBUG
export extern "C++" {
  namespace telar::runtime::trace {

    struct Record {
      const char* name;
      std::int64_t start;
      std::int64_t duration;
      std::uint64_t thread;
    };

    inline constexpr std::size_t buffer_capacity = 16 * 1024;

    consteval const char* literal(const char* name) {
      for (const char* character = name; *character; ++character) {
        if (*character == '"' || *character == '\\' || static_cast<unsigned char>(*character) < 0x20) {
          throw "Trace names must be JSON-safe literals";
        }
      }

      return name;
    }

    inline std::int64_t now() noexcept {
      return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
    }

    void record(const char* name, std::int64_t start, std::int64_t end) noexcept;
    void open(const char* path, std::span<Record> first, std::span<Record> second);
    void close() noexcept;

    class Scope {
    public:
      explicit Scope(const char* name) noexcept
          : name_(name),
            start_(now()) {}

      ~Scope() {
        record(name_, start_, now());
      }

      Scope(const Scope&) = delete;
      Scope& operator=(const Scope&) = delete;

    private:
      const char* name_;
      std::int64_t start_;
    };

    template <Allocator Memory>
    class Session {
    public:
      explicit Session(Memory& memory, const char* path)
          : buffers_(AllocatorRef<Record, Memory>{memory}) {
        if (path == nullptr) {
          return;
        }

        buffers_.resize(2 * buffer_capacity);
        open(path, std::span{buffers_}.first(buffer_capacity), std::span{buffers_}.subspan(buffer_capacity));
        active_ = true;
      }

      ~Session() {
        if (active_) {
          close();
        }
      }

      Session(const Session&) = delete;
      Session& operator=(const Session&) = delete;

    private:
      Vector<Record, Memory> buffers_;
      bool active_ = false;
    };

    template <Allocator Memory>
    Session(Memory& memory, const char* path) -> Session<Memory>;

  }
}
#endif

module;
#include "telar_platform/file_descriptor.hpp"

export module telar.platform.primitives;

import std;
import telar.tbc;

// The descriptors, mappings and shared memory below are POSIX objects: their
// importers reach the system calls that operate on them from telar.sys.
import telar.sys.posix;
import telar.base.ds;

#if TELAR_DEBUG
import telar.base.memory.allocators;
#endif

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::runtime {
  using telar::runtime::duplicateCloseOnExec;
  using telar::runtime::FileDescriptor;
  using telar::runtime::setCloseOnExec;
  using telar::runtime::setNonblocking;
}

export namespace telar::runtime {

  // A shared mapping of a descriptor's first `length` bytes, unmapped when it goes; empty when
  // the system refuses it.
  class MappedRegion {
  public:
    MappedRegion() noexcept = default;
    explicit MappedRegion(int descriptor, std::size_t length, int protection) noexcept;
    ~MappedRegion();

    MappedRegion(const MappedRegion&) = delete;
    MappedRegion& operator=(const MappedRegion&) = delete;

    constexpr MappedRegion(MappedRegion&& other) noexcept
        : bytes_(std::exchange(other.bytes_, {})) {}

    MappedRegion& operator=(MappedRegion&& other) noexcept;

    constexpr explicit operator bool() const noexcept {
      return !bytes_.empty();
    }

    [[nodiscard]] constexpr std::span<std::uint8_t> bytes() const noexcept {
      return bytes_;
    }

    bool protect(int protection) noexcept;

  private:
    void reset() noexcept;

    std::span<std::uint8_t> bytes_;
  };

  // The name a graphics client gives a shared memory object, terminated in the caller's
  // destination: copied from its decoded bytes, or decoded from base64. None when it is empty,
  // holds a NUL or does not fit.
  tbc::val_a<const char*> copyGraphicsName(std::span<const std::uint8_t> decoded, tbc::val_a<std::span<std::uint8_t>> destination) noexcept;
  tbc::val_a<const char*> decodeGraphicsName(std::string_view encoded, tbc::val_a<std::span<std::uint8_t>> destination) noexcept;

  // The POSIX shared memory a graphics client names in a kitty transmission, opened read-only.
  class GraphicsChildSharedMemory {
  public:
    static FileDescriptor open(std::string_view encoded_name, std::span<std::uint8_t> name) noexcept;
    static FileDescriptor openDecoded(std::span<const std::uint8_t> decoded_name, std::span<std::uint8_t> name) noexcept;

    // Fills `output` from `offset`; false when the object is shorter or cannot be read.
    static bool read(int descriptor, std::span<std::uint8_t> output, std::uint64_t offset) noexcept;
    static void release(std::string_view encoded_name) noexcept;
  };

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
      for (const char* character = name; (*character) != 0; ++character) {
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
          : buffers_(memory) {
        if (path == nullptr) {
          return;
        }

        buffers_.resize(2 * buffer_capacity);
        open(path, buffers_.viewMut().first(buffer_capacity), buffers_.viewMut().subspan(buffer_capacity));
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
      ds::Vec<Record, Memory> buffers_;
      bool active_ = false;
    };

    template <Allocator Memory>
    Session(Memory& memory, const char* path) -> Session<Memory>;

  }
}
#endif

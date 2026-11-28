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

export namespace telar::runtime {

  class FileDescriptor {
  public:
    constexpr explicit FileDescriptor(int descriptor = -1) noexcept
        : descriptor_(descriptor) {}

    ~FileDescriptor();

    FileDescriptor(const FileDescriptor&) = delete;
    FileDescriptor& operator=(const FileDescriptor&) = delete;

    constexpr FileDescriptor(FileDescriptor&& other) noexcept
        : descriptor_(other.release()) {}

    FileDescriptor& operator=(FileDescriptor&& other) noexcept;

    [[nodiscard]] constexpr int get() const noexcept {
      return descriptor_;
    }

    constexpr explicit operator bool() const noexcept {
      return descriptor_ >= 0;
    }

    constexpr int release() noexcept {
      return std::exchange(descriptor_, -1);
    }

    void reset(int descriptor = -1) noexcept;

  private:
    int descriptor_;
  };

  void setNonblocking(int descriptor);
  void setCloseOnExec(int descriptor);
  [[nodiscard]] FileDescriptor duplicateCloseOnExec(int descriptor, int minimum);

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

  // The system calls take their flags as an int, such as open(2)'s O_* and flock(2)'s LOCK_*;
  // the bits are combined unsigned.
  template <std::same_as<int>... Flag>
  constexpr int combineFlags(Flag... flags) noexcept {
    return static_cast<int>((0U | ... | static_cast<unsigned>(flags)));
  }

  // Fills `size` bytes at `data` from the kernel's random source, never
  // failing: arc4random_buf on macOS, getrandom on Linux, where musl has no
  // arc4random. A Linux that cannot answer getrandom aborts rather than hand
  // out predictable nonces.
  void randomBytes(void* data, std::size_t size) noexcept;

}

// The trace sink is defined in src/trace.cpp, a translation unit outside the module, so its
// declarations belong to the global module.
#if TELAR_DEBUG
// NOLINTBEGIN(misc-use-internal-linkage): exported, and declared in the global module for trace.cpp.
export extern "C++" {
  namespace telar::runtime::trace {

    struct Record {
      const char* name;
      std::int64_t start;
      std::int64_t duration;
      std::uint64_t thread;
    };

    inline constexpr std::size_t buffer_capacity = std::size_t{16} * 1024;

    consteval const char* literal(const char* name) {
      // JSON escapes the control characters below the space.
      constexpr unsigned char first_unescaped = 0x20;

      for (const char* character = name; (*character) != 0; ++character) {
        if (*character == '"' || *character == '\\' || static_cast<unsigned char>(*character) < first_unescaped) {
          throw std::invalid_argument{"Trace names must be JSON-safe literals"};
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
      Scope(Scope&&) = delete;
      Scope& operator=(Scope&&) = delete;

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
      Session(Session&&) = delete;
      Session& operator=(Session&&) = delete;

    private:
      ds::Vec<Record, Memory> buffers_;
      bool active_ = false;
    };

    template <Allocator Memory>
    Session(Memory& memory, const char* path) -> Session<Memory>;

  }
}
// NOLINTEND(misc-use-internal-linkage)
#endif

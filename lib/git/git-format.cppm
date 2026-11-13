module;
#include <cerrno>
#include <fcntl.h>
#include <openssl/sha.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

export module telar.git:format;

import std;
import telar.base.memory;
import telar.platform;
import telar.platform.primitives;

// Byte-level primitives every other part of the reader shares: object ids,
// hashing, bounded file reads beneath a directory descriptor and file
// fingerprints. Everything read from a repository is untrusted input.

export namespace telar::git {

// Upper bounds on what one read may consume. Exceeding one reports the
// affected part as unknown instead of reading further.
struct Limits {
  std::size_t small_file = 4096;               // HEAD, loose refs, .git files, commondir
  std::size_t config_file = 1 << 20;           // config, config.worktree
  std::size_t packed_refs = 64 << 20;
  std::size_t shallow_file = 16 << 20;
  std::size_t index_file = 256 << 20;
  std::size_t index_entries = 1 << 21;
  std::size_t path_length = 4095;              // one index path or ref name
  std::size_t path_depth = 128;                // directory components of one index path
  std::size_t discovery_depth = 256;           // parent directories walked to find .git
  std::size_t symbolic_depth = 5;              // chained symbolic refs, as git's SYMREF_MAXDEPTH
  std::size_t packs = 1024;
  std::size_t object_size = 64 << 20;          // one inflated object or delta result
  std::size_t delta_depth = 128;
  std::size_t inflated_bytes = 256 << 20;      // inflated and delta-applied by one read
  std::size_t commit_header = 64 << 10;        // bytes of a commit inspected for its header
  std::size_t commit_parents = 128;
  std::size_t commit_graph_layers = 64;
  std::size_t walk_commits = 20000;            // commits visited by one ahead/behind walk
  std::size_t tree_objects = 20000;            // trees read by one HEAD-to-index comparison
  std::size_t hashed_bytes = 64 << 20;         // working tree bytes hashed by one read
};

enum class ObjectFormat : std::uint8_t {
  sha1,
  sha256
};

inline constexpr std::size_t maximum_hash_size = 32;
inline constexpr std::size_t default_abbreviation = 7;

inline constexpr std::size_t hashSize(ObjectFormat format) noexcept {
  return format == ObjectFormat::sha1 ? 20 : 32;
}

inline constexpr int hexValue(char digit) noexcept {
  if (digit >= '0' && digit <= '9') {
    return digit - '0';
  }
  if (digit >= 'a' && digit <= 'f') {
    return digit - 'a' + 10;
  }
  if (digit >= 'A' && digit <= 'F') {
    return digit - 'A' + 10;
  }
  return -1;
}

struct ObjectId {
  std::array<std::uint8_t, maximum_hash_size> bytes{};
  std::uint8_t size = 0;

  friend bool operator==(const ObjectId &, const ObjectId &) = default;

  inline explicit operator bool() const noexcept { return size != 0; }

  inline std::span<const std::uint8_t> view() const noexcept { return {bytes.data(), size}; }

  // The first `digits` hexadecimal digits, written into `buffer`.
  inline std::string_view hex(std::span<char, 2 * maximum_hash_size> buffer, std::size_t digits = 2 * maximum_hash_size) const noexcept {
    constexpr std::string_view alphabet = "0123456789abcdef";
    digits = std::min(digits, std::size_t{size} * 2);
    for (std::size_t index = 0; index < digits; ++index) {
      const auto byte = bytes[index / 2];
      buffer[index] = alphabet[index % 2 == 0 ? byte >> 4 : byte & 15];
    }
    return {buffer.data(), digits};
  }

  inline static std::optional<ObjectId> fromHex(std::string_view text, ObjectFormat format) noexcept {
    const auto size = hashSize(format);
    if (text.size() != 2 * size) {
      return std::nullopt;
    }
    ObjectId id;
    id.size = static_cast<std::uint8_t>(size);
    for (std::size_t index = 0; index < size; ++index) {
      const auto high = hexValue(text[2 * index]);
      const auto low = hexValue(text[2 * index + 1]);
      if (high < 0 || low < 0) {
        return std::nullopt;
      }
      id.bytes[index] = static_cast<std::uint8_t>(high << 4 | low);
    }
    return id;
  }

  // `raw` holds at most maximum_hash_size bytes; callers check its bounds.
  inline static ObjectId fromBytes(std::span<const std::uint8_t> raw) noexcept {
    ObjectId id;
    id.size = static_cast<std::uint8_t>(std::min(raw.size(), maximum_hash_size));
    std::copy_n(raw.begin(), id.size, id.bytes.begin());
    return id;
  }
};

// The identity and change markers of one file, from lstat-like data. Two
// equal fingerprints mean git rewrote nothing: it replaces files by rename.
struct Fingerprint {
  std::uint64_t device = 0;
  std::uint64_t inode = 0;
  std::uint64_t size = 0;
  std::int64_t modified_seconds = 0;
  std::int64_t modified_nanoseconds = 0;
  std::int64_t changed_seconds = 0;
  std::int64_t changed_nanoseconds = 0;
  std::uint32_t mode = 0;
  bool present = false;

  friend bool operator==(const Fingerprint &, const Fingerprint &) = default;
};

}

namespace telar::git {

using telar::runtime::FileDescriptor;

#if defined(__APPLE__)
inline const timespec &modifiedTime(const struct stat &status) noexcept { return status.st_mtimespec; }
inline const timespec &changedTime(const struct stat &status) noexcept { return status.st_ctimespec; }
#else
inline const timespec &modifiedTime(const struct stat &status) noexcept { return status.st_mtim; }
inline const timespec &changedTime(const struct stat &status) noexcept { return status.st_ctim; }
#endif

inline Fingerprint fingerprintOf(const struct stat &status) noexcept {
  return {
      .device = static_cast<std::uint64_t>(status.st_dev),
      .inode = static_cast<std::uint64_t>(status.st_ino),
      .size = static_cast<std::uint64_t>(status.st_size),
      .modified_seconds = static_cast<std::int64_t>(modifiedTime(status).tv_sec),
      .modified_nanoseconds = static_cast<std::int64_t>(modifiedTime(status).tv_nsec),
      .changed_seconds = static_cast<std::int64_t>(changedTime(status).tv_sec),
      .changed_nanoseconds = static_cast<std::int64_t>(changedTime(status).tv_nsec),
      .mode = static_cast<std::uint32_t>(status.st_mode),
      .present = true,
  };
}

// The fingerprint of `name` beneath `directory`, without following a final
// symlink. An absent or unreadable entry has no fingerprint.
inline Fingerprint fingerprintAt(int directory, const char *name) noexcept {
  struct stat status{};
  if (directory < 0 || ::fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
    return {};
  }
  return fingerprintOf(status);
}

inline bool sameFile(const struct stat &left, const struct stat &right) noexcept {
  return left.st_dev == right.st_dev && left.st_ino == right.st_ino;
}

inline std::span<const std::uint8_t> asBytes(std::string_view text) noexcept {
  return {reinterpret_cast<const std::uint8_t *>(text.data()), text.size()};
}

inline std::string_view asText(std::span<const std::uint8_t> bytes) noexcept {
  return {reinterpret_cast<const char *>(bytes.data()), bytes.size()};
}

// True when [offset, offset + count) lies within `size` bytes, without overflow.
inline constexpr bool fits(std::uint64_t size, std::uint64_t offset, std::uint64_t count) noexcept {
  return offset <= size && count <= size - offset;
}

inline std::uint16_t loadBig16(const std::uint8_t *bytes) noexcept {
  return static_cast<std::uint16_t>(bytes[0] << 8 | bytes[1]);
}

inline std::uint32_t loadBig32(const std::uint8_t *bytes) noexcept {
  return std::uint32_t{bytes[0]} << 24 | std::uint32_t{bytes[1]} << 16 | std::uint32_t{bytes[2]} << 8 | bytes[3];
}

inline std::uint64_t loadBig64(const std::uint8_t *bytes) noexcept {
  return std::uint64_t{loadBig32(bytes)} << 32 | loadBig32(bytes + 4);
}

inline int compareBytes(std::span<const std::uint8_t> left, std::span<const std::uint8_t> right) noexcept {
  const auto common = std::min(left.size(), right.size());
  if (common != 0) {
    if (const auto order = std::memcmp(left.data(), right.data(), common); order != 0) {
      return order;
    }
  }
  return left.size() < right.size() ? -1 : left.size() > right.size() ? 1 : 0;
}

// A NUL-terminated name for the *at() calls, assembled without allocating.
class PathName {
public:
  inline PathName() noexcept { bytes_[0] = '\0'; }

  inline bool assign(std::initializer_list<std::string_view> parts) noexcept {
    length_ = 0;
    for (const auto part : parts) {
      if (part.size() >= bytes_.size() - length_ || part.contains('\0')) {
        length_ = 0;
        bytes_[0] = '\0';
        return false;
      }
      std::copy(part.begin(), part.end(), bytes_.begin() + static_cast<std::ptrdiff_t>(length_));
      length_ += part.size();
    }
    bytes_[length_] = '\0';
    return true;
  }

  inline const char *c_str() const noexcept { return bytes_.data(); }

  inline std::string_view view() const noexcept { return {bytes_.data(), length_}; }

private:
  std::array<char, 4096> bytes_;
  std::size_t length_ = 0;
};

enum class ReadStatus : std::uint8_t {
  ok,
  missing,
  invalid
};

// Opens a regular file beneath `directory`. A final symlink, a FIFO, a device
// or a directory is refused; O_NONBLOCK keeps a FIFO from blocking the open.
inline ReadStatus openRegular(int directory, const char *name, FileDescriptor &file, struct stat &status) noexcept {
  file.reset(::openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | O_NOCTTY));
  if (!file) {
    return errno == ENOENT || errno == ENOTDIR ? ReadStatus::missing : ReadStatus::invalid;
  }
  if (::fstat(file.get(), &status) != 0 || !S_ISREG(status.st_mode) || status.st_size < 0) {
    file.reset();
    return ReadStatus::invalid;
  }
  return ReadStatus::ok;
}

// Reads exactly `size` bytes and confirms the file ends there, so a file that
// grows or shrinks while it is read is refused rather than half-parsed.
inline bool readExactly(int descriptor, char *destination, std::size_t size) noexcept {
  std::size_t offset = 0;
  while (offset < size) {
    const auto count = ::read(descriptor, destination + offset, size - offset);
    if (count > 0) {
      offset += static_cast<std::size_t>(count);
    } else if (count < 0 && errno == EINTR) {
      continue;
    } else {
      return false;
    }
  }
  char extra;
  ssize_t count;
  do {
    count = ::read(descriptor, &extra, 1);
  } while (count < 0 && errno == EINTR);
  return count == 0;
}

inline bool readAt(int descriptor, void *destination, std::size_t size, std::uint64_t offset) noexcept {
  auto *bytes = static_cast<char *>(destination);
  std::size_t done = 0;
  while (done < size) {
    if (offset + done > static_cast<std::uint64_t>(std::numeric_limits<off_t>::max())) {
      return false;
    }
    const auto count = ::pread(descriptor, bytes + done, size - done, static_cast<off_t>(offset + done));
    if (count > 0) {
      done += static_cast<std::size_t>(count);
    } else if (count < 0 && errno == EINTR) {
      continue;
    } else {
      return false;
    }
  }
  return true;
}

// Reads a small file into a caller buffer; files that do not fit are invalid.
inline ReadStatus readSmall(int directory, const char *name, std::span<char> buffer, std::string_view &contents, Fingerprint *fingerprint = nullptr) noexcept {
  FileDescriptor file;
  struct stat status{};
  if (const auto opened = openRegular(directory, name, file, status); opened != ReadStatus::ok) {
    return opened;
  }
  const auto size = static_cast<std::uint64_t>(status.st_size);
  if (size > buffer.size() || !readExactly(file.get(), buffer.data(), static_cast<std::size_t>(size))) {
    return ReadStatus::invalid;
  }
  if (fingerprint != nullptr) {
    *fingerprint = fingerprintOf(status);
  }
  contents = {buffer.data(), static_cast<std::size_t>(size)};
  return ReadStatus::ok;
}

// Reads a whole file of at most `limit` bytes into `bytes`, which keeps its capacity.
template <Allocator Memory>
ReadStatus readWhole(int directory, const char *name, String<Memory> &bytes, std::size_t limit, Fingerprint *fingerprint = nullptr) {
  bytes.clear();
  FileDescriptor file;
  struct stat status{};
  if (const auto opened = openRegular(directory, name, file, status); opened != ReadStatus::ok) {
    return opened;
  }
  const auto size = static_cast<std::uint64_t>(status.st_size);
  if (size > limit) {
    return ReadStatus::invalid;
  }
  bool complete = false;
  bytes.resize_and_overwrite(static_cast<std::size_t>(size), [&](char *destination, std::size_t count) {
    complete = readExactly(file.get(), destination, count);
    return complete ? count : 0;
  });
  if (!complete) {
    bytes.clear();
    return ReadStatus::invalid;
  }
  if (fingerprint != nullptr) {
    *fingerprint = fingerprintOf(status);
  }
  return ReadStatus::ok;
}

inline FileDescriptor openDirectory(int directory, const char *name) noexcept {
  return FileDescriptor{::openat(directory, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
}

class Sha1 {
public:
  inline Sha1() noexcept { SHA1_Init(&context_); }

  inline void update(std::span<const std::uint8_t> bytes) noexcept { SHA1_Update(&context_, bytes.data(), bytes.size()); }

  inline std::array<std::uint8_t, SHA_DIGEST_LENGTH> finish() noexcept {
    std::array<std::uint8_t, SHA_DIGEST_LENGTH> digest;
    SHA1_Final(digest.data(), &context_);
    return digest;
  }

private:
  SHA_CTX context_;
};

// The object hash of the repository's format.
class Hasher {
public:
  inline explicit Hasher(ObjectFormat format) noexcept : format_(format) {}

  inline void update(std::span<const std::uint8_t> bytes) noexcept {
    if (format_ == ObjectFormat::sha1) {
      sha1_.update(bytes);
    } else {
      sha256_.update(asText(bytes));
    }
  }

  inline ObjectId finish() noexcept {
    if (format_ == ObjectFormat::sha1) {
      const auto digest = sha1_.finish();
      return ObjectId::fromBytes(digest);
    }
    const auto digest = sha256_.finish();
    return ObjectId::fromBytes(digest);
  }

private:
  ObjectFormat format_;
  Sha1 sha1_;
  telar::runtime::Sha256 sha256_;
};

inline ObjectId hashBytes(ObjectFormat format, std::span<const std::uint8_t> bytes) noexcept {
  Hasher hasher{format};
  hasher.update(bytes);
  return hasher.finish();
}

// Starts hashing an object as git does: "<type> <size>\0" precedes its bytes.
inline void hashObjectHeader(Hasher &hasher, std::string_view type, std::uint64_t size) noexcept {
  std::array<char, 48> header;
  std::copy(type.begin(), type.end(), header.begin());
  auto *cursor = header.data() + type.size();
  *cursor++ = ' ';
  cursor = std::to_chars(cursor, header.data() + header.size() - 1, size).ptr;
  *cursor++ = '\0';
  hasher.update(asBytes({header.data(), static_cast<std::size_t>(cursor - header.data())}));
}

inline ObjectId emptyBlob(ObjectFormat format) noexcept {
  Hasher hasher{format};
  hashObjectHeader(hasher, "blob", 0);
  return hasher.finish();
}

// git's check_refname_format for a full ref name, which also keeps a name
// from escaping the refs directory: no "..", no component starting with ".".
inline bool validReferenceName(std::string_view name, std::size_t maximum_length) noexcept {
  if (name.empty() || name.size() > maximum_length || name == "@" || name.front() == '/' || name.back() == '/' || name.back() == '.') {
    return false;
  }
  std::size_t component_start = 0;
  for (std::size_t index = 0; index <= name.size(); ++index) {
    if (index == name.size() || name[index] == '/') {
      const auto component = name.substr(component_start, index - component_start);
      if (component.empty() || component.front() == '.' || component.ends_with(".lock")) {
        return false;
      }
      component_start = index + 1;
      continue;
    }
    const auto byte = static_cast<unsigned char>(name[index]);
    if (byte < 0x20 || byte == 0x7f) {
      return false;
    }
    switch (name[index]) {
    case ' ':
    case '~':
    case '^':
    case ':':
    case '?':
    case '*':
    case '[':
    case '\\':
      return false;
    case '.':
      if (index + 1 < name.size() && name[index + 1] == '.') {
        return false;
      }
      break;
    case '@':
      if (index + 1 < name.size() && name[index + 1] == '{') {
        return false;
      }
      break;
    default:
      break;
    }
  }
  return true;
}

}

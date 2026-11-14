module;
#include <cerrno>
#include <fcntl.h>
#include <openssl/sha.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

module telar.git;

import std;

namespace telar::git {

  namespace {

#if defined(__APPLE__)
    const timespec& modifiedTime(const struct stat& status) noexcept {
      return status.st_mtimespec;
    }

    const timespec& changedTime(const struct stat& status) noexcept {
      return status.st_ctimespec;
    }
#else
    const timespec& modifiedTime(const struct stat& status) noexcept {
      return status.st_mtim;
    }

    const timespec& changedTime(const struct stat& status) noexcept {
      return status.st_ctim;
    }
#endif

    // Reads exactly `size` bytes and confirms the file ends there, so a file that
    // grows or shrinks while it is read is refused rather than half-parsed.
    bool readExactly(int descriptor, char* destination, std::size_t size) noexcept {
      std::size_t offset = 0;

      while (offset < size) {
        const auto count = ::read(descriptor, destination + offset, size - offset);
        if (count > 0) {
          offset += static_cast<std::size_t>(count);
        } else if (count < 0 && sys::lastError() == EINTR) {
          continue;
        } else {
          return false;
        }
      }

      char extra;
      ssize_t count;

      do {
        count = ::read(descriptor, &extra, 1);
      } while (count < 0 && sys::lastError() == EINTR);

      return count == 0;
    }

  }

  ObjectId::operator bool() const noexcept {
    return size != 0;
  }

  std::span<const std::uint8_t> ObjectId::view() const noexcept {
    return {bytes.data(), size};
  }

  std::string_view ObjectId::hex(std::span<char, 2 * maximum_hash_size> buffer, std::size_t digits) const noexcept {
    constexpr std::string_view alphabet = "0123456789abcdef";

    digits = std::min(digits, std::size_t{size} * 2);
    for (std::size_t index = 0; index < digits; ++index) {
      const auto byte = bytes[index / 2];

      buffer[index] = alphabet[index % 2 == 0 ? byte >> 4 : byte & 15];
    }

    return {buffer.data(), digits};
  }

  std::optional<ObjectId> ObjectId::fromHex(std::string_view text, ObjectFormat format) noexcept {
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

  ObjectId ObjectId::fromBytes(std::span<const std::uint8_t> raw) noexcept {
    ObjectId id;

    id.size = static_cast<std::uint8_t>(std::min(raw.size(), maximum_hash_size));
    std::copy_n(raw.begin(), id.size, id.bytes.begin());
    return id;
  }

  Fingerprint fingerprintOf(const struct stat& status) noexcept {
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

  Fingerprint fingerprintAt(int directory, const char* name) noexcept {
    struct stat status{};
    if (directory < 0 || ::fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
      return {};
    }

    return fingerprintOf(status);
  }

  bool sameFile(const struct stat& left, const struct stat& right) noexcept {
    return left.st_dev == right.st_dev && left.st_ino == right.st_ino;
  }

  std::span<const std::uint8_t> asBytes(std::string_view text) noexcept {
    return {reinterpret_cast<const std::uint8_t*>(text.data()), text.size()};
  }

  std::string_view asText(std::span<const std::uint8_t> bytes) noexcept {
    return {reinterpret_cast<const char*>(bytes.data()), bytes.size()};
  }

  std::uint16_t loadBig16(const std::uint8_t* bytes) noexcept {
    return static_cast<std::uint16_t>(bytes[0] << 8 | bytes[1]);
  }

  std::uint32_t loadBig32(const std::uint8_t* bytes) noexcept {
    return std::uint32_t{bytes[0]} << 24 | std::uint32_t{bytes[1]} << 16 | std::uint32_t{bytes[2]} << 8 | bytes[3];
  }

  std::uint64_t loadBig64(const std::uint8_t* bytes) noexcept {
    return std::uint64_t{loadBig32(bytes)} << 32 | loadBig32(bytes + 4);
  }

  int compareBytes(std::span<const std::uint8_t> left, std::span<const std::uint8_t> right) noexcept {
    const auto common = std::min(left.size(), right.size());
    if (common != 0) {
      if (const auto order = std::memcmp(left.data(), right.data(), common); order != 0) {
        return order;
      }
    }

    return left.size() < right.size() ? -1 : left.size() > right.size() ? 1
                                                                        : 0;
  }

  PathName::PathName() noexcept {
    bytes_[0] = '\0';
  }

  bool PathName::assign(std::initializer_list<std::string_view> parts) noexcept {
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

  const char* PathName::c_str() const noexcept {
    return bytes_.data();
  }

  std::string_view PathName::view() const noexcept {
    return {bytes_.data(), length_};
  }

  ReadStatus openRegular(int directory, const char* name, FileDescriptor& file, struct stat& status) noexcept {
    file.reset(::openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | O_NOCTTY));
    if (!file) {
      return sys::lastError() == ENOENT || sys::lastError() == ENOTDIR ? ReadStatus::missing : ReadStatus::invalid;
    }

    if (::fstat(file.get(), &status) != 0 || !S_ISREG(status.st_mode) || status.st_size < 0) {
      file.reset();
      return ReadStatus::invalid;
    }

    return ReadStatus::ok;
  }

  bool readAt(int descriptor, void* destination, std::size_t size, std::uint64_t offset) noexcept {
    auto* bytes = static_cast<char*>(destination);
    std::size_t done = 0;

    while (done < size) {
      if (offset + done > static_cast<std::uint64_t>(std::numeric_limits<off_t>::max())) {
        return false;
      }

      const auto count = ::pread(descriptor, bytes + done, size - done, static_cast<off_t>(offset + done));
      if (count > 0) {
        done += static_cast<std::size_t>(count);
      } else if (count < 0 && sys::lastError() == EINTR) {
        continue;
      } else {
        return false;
      }
    }

    return true;
  }

  ReadStatus readSmall(int directory, const char* name, std::span<char> buffer, std::string_view& contents, Fingerprint* fingerprint) noexcept {
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

  template <Allocator Memory>
  ReadStatus readWhole(int directory, const char* name, String<Memory>& bytes, std::size_t limit, Fingerprint* fingerprint) {
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

    bytes.resize_and_overwrite(static_cast<std::size_t>(size), [&](char* destination, std::size_t count) {
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

  template ReadStatus readWhole<Memory>(int directory, const char* name, String<Memory>& bytes, std::size_t limit, Fingerprint* fingerprint);

  FileDescriptor openDirectory(int directory, const char* name) noexcept {
    return FileDescriptor{::openat(directory, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
  }

  Sha1::Sha1() noexcept {
    SHA1_Init(&context_);
  }

  void Sha1::update(std::span<const std::uint8_t> bytes) noexcept {
    SHA1_Update(&context_, bytes.data(), bytes.size());
  }

  std::array<std::uint8_t, SHA_DIGEST_LENGTH> Sha1::finish() noexcept {
    std::array<std::uint8_t, SHA_DIGEST_LENGTH> digest;

    SHA1_Final(digest.data(), &context_);
    return digest;
  }

  Hasher::Hasher(ObjectFormat format) noexcept
      : format_(format) {}

  void Hasher::update(std::span<const std::uint8_t> bytes) noexcept {
    if (format_ == ObjectFormat::sha1) {
      sha1_.update(bytes);
    } else {
      sha256_.update(asText(bytes));
    }
  }

  ObjectId Hasher::finish() noexcept {
    if (format_ == ObjectFormat::sha1) {
      const auto digest = sha1_.finish();

      return ObjectId::fromBytes(digest);
    }

    const auto digest = sha256_.finish();

    return ObjectId::fromBytes(digest);
  }

  ObjectId hashBytes(ObjectFormat format, std::span<const std::uint8_t> bytes) noexcept {
    Hasher hasher{format};

    hasher.update(bytes);
    return hasher.finish();
  }

  void hashObjectHeader(Hasher& hasher, std::string_view type, std::uint64_t size) noexcept {
    std::array<char, 48> header;

    std::copy(type.begin(), type.end(), header.begin());
    auto* cursor = header.data() + type.size();

    *cursor++ = ' ';
    cursor = std::to_chars(cursor, header.data() + header.size() - 1, size).ptr;
    *cursor++ = '\0';
    hasher.update(asBytes({header.data(), static_cast<std::size_t>(cursor - header.data())}));
  }

  ObjectId emptyBlob(ObjectFormat format) noexcept {
    Hasher hasher{format};

    hashObjectHeader(hasher, "blob", 0);
    return hasher.finish();
  }

  bool validReferenceName(std::string_view name, std::size_t maximum_length) noexcept {
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

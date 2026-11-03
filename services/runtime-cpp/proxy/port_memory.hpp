#pragma once

#include "port_range.hpp"
#include "telar_platform/private_file.hpp"
#include "telar_platform/sha256.hpp"
#include "telar_platform/write_private_file.hpp"
#include <charconv>
#include <dirent.h>
#include <optional>

namespace telar::runtime {

template <Allocator Memory>
class ProxyPortMemory {
public:
  explicit ProxyPortMemory(Memory &memory, int directory, std::string_view endpoint, bool inherit_legacy)
      : memory_(memory),
        directory_(directory),
        endpoint_(endpoint, AllocatorRef<char, Memory>{memory}) {
    if (endpoint.size() > PATH_MAX || endpoint.contains('\0')) {
      throw SystemError{"Invalid proxy endpoint path", EINVAL};
    }

    identify(endpoint);
    Vector<unsigned char, Memory> bytes{AllocatorRef<unsigned char, Memory>{memory_}};
    if (const auto record = recall(name_.data(), bytes)) {
      own_ = record->port;
    }
    if (inherit_legacy) {
      if (const auto record = recall(legacy_name, bytes)) {
        legacy_ = record->port;
      }
    }

    scan([&](const char *name, const Record &record) {
      if (vanished(record.endpoint)) {
        ::unlinkat(directory_, name, 0);
      } else {
        reserved_.set(record.port - ProxyPortRange::first);
      }
    });
    if (own_ && legacy_) {
      reserved_.set(*legacy_ - ProxyPortRange::first);
    }
  }

  std::optional<std::uint16_t> preferred() const noexcept {
    return own_ ? own_ : legacy_;
  }

  const ProxyPortRange::Set &reserved() const noexcept {
    return reserved_;
  }

  std::string_view filename() const noexcept {
    return {name_.data(), filename_bytes};
  }

  bool remember(std::uint16_t port) noexcept {
    if (!ProxyPortRange::contains(port)) {
      return false;
    }

    std::array<char, maximum_record_bytes> record;
    auto *end = std::to_chars(record.data(), record.data() + record.size(), port).ptr;
    *end++ = '\n';
    end = std::copy(endpoint_.begin(), endpoint_.end(), end);
    *end++ = '\n';
    const auto bytes = std::span{reinterpret_cast<const std::uint8_t *>(record.data()), static_cast<std::size_t>(end - record.data())};
    if (writePrivateFile(directory_, filename(), bytes, PrivateFileMode::replace) != 0) {
      return false;
    }

    if (!own_ && legacy_ == port) {
      ::unlinkat(directory_, legacy_name, 0);
    }
    if (reserved_.test(port - ProxyPortRange::first)) {
      scan([&](const char *name, const Record &record) {
        if (record.port == port) {
          ::unlinkat(directory_, name, 0);
        }
      });
    }
    return true;
  }

private:
  struct Record {
    std::uint16_t port;
    std::string_view endpoint;
  };

  struct DirectoryCloser {
    void operator()(DIR *directory) const noexcept {
      ::closedir(directory);
    }
  };

  void identify(std::string_view endpoint) noexcept {
    Sha256 hash;
    hash.update(endpoint);
    const auto digest = hash.finish();
    auto *end = std::copy(file_prefix.begin(), file_prefix.end(), name_.begin());
    for (std::size_t index = 0; index < digest_bytes; ++index) {
      *end++ = hexadecimal[digest[index] >> 4];
      *end++ = hexadecimal[digest[index] & 15];
    }
    *end = '\0';
  }

  std::optional<Record> recall(std::string_view name, Vector<unsigned char, Memory> &bytes) const noexcept {
    try {
      if (!readPrivateFile(directory_, name, bytes, maximum_record_bytes)) {
        return std::nullopt;
      }
    } catch (...) {
      return std::nullopt;
    }

    const std::string_view text{reinterpret_cast<const char *>(bytes.data()), bytes.size()};
    const auto newline = text.find('\n');
    auto number = trimCarriageReturns(text.substr(0, newline));
    if (number.starts_with('+')) {
      number.remove_prefix(1);
    }
    if (number.empty() || number.front() == '_' || number.back() == '_') {
      return std::nullopt;
    }

    std::uint32_t port = 0;
    for (const char character : number) {
      if (character == '_') {
        continue;
      }
      if (character < '0' || character > '9') {
        return std::nullopt;
      }
      port = port * 10 + static_cast<unsigned>(character - '0');
      if (port > UINT16_MAX) {
        return std::nullopt;
      }
    }
    if (!ProxyPortRange::contains(static_cast<std::uint16_t>(port))) {
      return std::nullopt;
    }

    const auto tail = newline == std::string_view::npos ? std::string_view{} : text.substr(newline + 1);
    return Record{static_cast<std::uint16_t>(port), trimCarriageReturns(tail.substr(0, tail.find('\n')))};
  }

  template <typename Visitor>
  void scan(const Visitor &visit) const noexcept {
    try {
      FileDescriptor descriptor{::openat(directory_, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
      if (!descriptor) {
        return;
      }
      std::unique_ptr<DIR, DirectoryCloser> directory{::fdopendir(descriptor.get())};
      if (!directory) {
        return;
      }
      descriptor.release();

      Vector<unsigned char, Memory> bytes{AllocatorRef<unsigned char, Memory>{memory_}};
      for (std::size_t scanned = 0; scanned < maximum_scanned_entries; ++scanned) {
        const auto *entry = ::readdir(directory.get());
        if (entry == nullptr) {
          return;
        }
        const std::string_view name{entry->d_name};
        if (entry->d_type != DT_REG || name == filename() || !isPortFile(name)) {
          continue;
        }
        if (const auto record = recall(name, bytes)) {
          visit(entry->d_name, *record);
        }
      }
    } catch (...) {
    }
  }

  static bool isPortFile(std::string_view name) noexcept {
    return name.size() == filename_bytes && name.starts_with(file_prefix) && std::ranges::all_of(name.substr(file_prefix.size()), [](char byte) { return hexadecimal.contains(byte); });
  }

  static bool vanished(std::string_view endpoint) noexcept {
    if (!endpoint.starts_with('/') || endpoint.contains('\0')) {
      return false;
    }

    const auto separator = endpoint.rfind('/');
    std::array<char, PATH_MAX + 1> parent;
    const auto length = std::max<std::size_t>(separator, 1);
    if (length >= parent.size()) {
      return false;
    }
    std::copy_n(endpoint.data(), length, parent.data());
    parent[length] = '\0';
    struct stat metadata{};
    return ::stat(parent.data(), &metadata) != 0 && errno == ENOENT;
  }

  static std::string_view trimCarriageReturns(std::string_view text) noexcept {
    while (text.ends_with('\r')) {
      text.remove_suffix(1);
    }
    return text;
  }

  static constexpr std::string_view file_prefix = "proxy-port-";
  static constexpr std::string_view hexadecimal = "0123456789abcdef";
  static constexpr char legacy_name[] = "proxy-port";
  static constexpr std::size_t digest_bytes = 8;
  static constexpr std::size_t filename_bytes = file_prefix.size() + digest_bytes * 2;
  static constexpr std::size_t maximum_scanned_entries = 4096;
  static constexpr std::size_t maximum_record_bytes = 8 + PATH_MAX + 1;
  Memory &memory_;
  int directory_;
  String<Memory> endpoint_;
  std::array<char, filename_bytes + 1> name_;
  ProxyPortRange::Set reserved_;
  std::optional<std::uint16_t> own_;
  std::optional<std::uint16_t> legacy_;
};

template <Allocator Memory>
ProxyPortMemory(Memory &memory, int directory, std::string_view endpoint, bool inherit_legacy) -> ProxyPortMemory<Memory>;

}

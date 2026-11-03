#pragma once

#include "../../platform/git_files.hpp"
#include "payload.hpp"
#include "telar_base/text/decimal.hpp"
#include "telar_platform/directory_stream.hpp"
#include "telar_platform/process_environment.hpp"
#include <openssl/md5.h>

namespace telar::runtime::cli::hooks {

class SessionFiles {
public:
  template <EnvironmentLookup Environment>
  std::string_view codex(const Environment &environment) noexcept {
    try {
      const auto override = environment.lookup("CODEX_HOME");
      const auto home = override.empty() ? join(environment.lookup("HOME"), ".codex", root_) : copy(override, root_);
      if (!home) {
        return {};
      }

      DirectoryStream directory{FileDescriptor{::open(home->data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)}};
      std::optional<std::uint32_t> best;
      while (const auto *entry = directory.next()) {
        const std::string_view name{entry->d_name, std::strlen(entry->d_name)};
        if (entry->d_type != DT_REG || !name.starts_with("state_") || !name.ends_with(".sqlite")) {
          continue;
        }

        const auto number = name.substr(6, name.size() - 13);
        const auto version = unsignedDecimal<std::uint32_t>(number);
        if (version && (!best || *version > *best)) {
          best = *version;
        }
      }
      if (!best) {
        return {};
      }

      std::array<char, 32> filename;
      const auto length = std::snprintf(filename.data(), filename.size(), "state_%u.sqlite", *best);
      return join(*home, {filename.data(), static_cast<std::size_t>(length)}, path_).value_or("");
    } catch (const std::exception &) {
      return {};
    }
  }

  template <Allocator Memory, EnvironmentLookup Environment>
  std::string_view cursor(Payload<Memory> &input, const Environment &environment) noexcept {
    try {
      if (input.event() != "sessionStart" && input.event() != "beforeSubmitPrompt") {
        return {};
      }

      const auto chat = input.session();
      if (chat.empty() || chat.size() > 64 || !std::ranges::all_of(chat, [](unsigned char byte) { return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F') || byte == '-'; })) {
        return {};
      }

      const auto root = cursorRoot(environment);
      if (!root) {
        return {};
      }

      if (!input.workspace().empty()) {
        std::array<unsigned char, MD5_DIGEST_LENGTH> digest;
        MD5(reinterpret_cast<const unsigned char *>(input.workspace().data()), input.workspace().size(), digest.data());
        constexpr std::string_view digits = "0123456789abcdef";
        std::array<char, 32> encoded;
        for (std::size_t index = 0; index < digest.size(); ++index) {
          encoded[2 * index] = digits[digest[index] >> 4];
          encoded[2 * index + 1] = digits[digest[index] & 15];
        }
        if (const auto path = cursorPath(*root, {encoded.data(), encoded.size()}, chat)) {
          return *path;
        }
      }

      const auto chats = join(*root, "chats", path_);
      if (!chats) {
        return {};
      }

      DirectoryStream directory{FileDescriptor{::open(chats->data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)}};
      constexpr std::size_t maximum_directories = 4096;
      for (std::size_t count = 0; count < maximum_directories; ++count) {
        const auto *entry = directory.next();
        if (entry == nullptr) {
          break;
        }
        if (entry->d_type == DT_DIR && std::strlen(entry->d_name) == 32) {
          if (const auto path = cursorPath(*root, {entry->d_name, std::strlen(entry->d_name)}, chat)) {
            return *path;
          }
        }
      }
    } catch (const std::exception &) {
    }

    return {};
  }

private:
  template <EnvironmentLookup Environment>
  std::optional<std::string_view> cursorRoot(const Environment &environment) {
    if (const auto configured = environment.lookup("CURSOR_CONFIG_DIR"); !configured.empty()) {
      return copy(configured, root_);
    }
    if (const auto xdg = environment.lookup("XDG_CONFIG_HOME"); !xdg.empty()) {
      return join(xdg, "cursor", root_);
    }

    return join(environment.lookup("HOME"), ".cursor", root_);
  }

  std::optional<std::string_view> cursorPath(std::string_view root, std::string_view digest, std::string_view chat) {
    const auto length = std::snprintf(path_.data(), path_.size(), "%.*s/chats/%.*s/%.*s/meta.json", static_cast<int>(root.size()), root.data(), static_cast<int>(digest.size()), digest.data(), static_cast<int>(chat.size()), chat.data());
    if (length < 0 || static_cast<std::size_t>(length) >= path_.size()) {
      return std::nullopt;
    }

    struct stat status;
    return ::lstat(path_.data(), &status) == 0 && S_ISREG(status.st_mode) ? std::optional{std::string_view{path_.data(), static_cast<std::size_t>(length)}} : std::nullopt;
  }

  static std::optional<std::string_view> copy(std::string_view value, std::span<char> buffer) noexcept {
    if (value.empty() || value.size() >= buffer.size() || value.contains('\0')) {
      return std::nullopt;
    }

    std::memcpy(buffer.data(), value.data(), value.size());
    buffer[value.size()] = '\0';
    return std::string_view{buffer.data(), value.size()};
  }

  static std::optional<std::string_view> join(std::string_view root, std::string_view suffix, std::span<char> buffer) noexcept {
    return root.empty() ? std::nullopt : GitFiles::join(root, suffix, buffer);
  }

  std::array<char, PATH_MAX> root_;
  std::array<char, PATH_MAX> path_;
};

}

module;
#include "tbc/view.hpp"
#include <cerrno>
#include <fcntl.h>

export module telar.gui.platform.profile_file;

import std;

import telar.gui.core.primitives;
import telar.gui.platform.path_limits;
import telar.machines;
import telar.platform;
import telar.platform.primitives;
import telar.vocabulary;

export {
  namespace telar::gui::platform {

    class InsecureProfileFile final : public std::runtime_error {
    public:
      inline InsecureProfileFile()
          : std::runtime_error("InsecureFile") {}
    };

    class ProfileFile;

    class ProfileOperationCancelled final : public std::exception {
    public:
      [[nodiscard]] inline const char* what() const noexcept override {
        return "Machine profile operation cancelled";
      }
    };

    template <Allocator Memory>
    // The source bytes are allocated from memory, region `a`.
    [[nodiscard]] tbc::view<std::optional<Vector<Byte, Memory>>, tbc::lt::a> readProfileSource(tbc::view<Memory&, tbc::lt::a> memory, int directory, std::string_view name) {
      Vector<Byte, Memory> bytes{AllocatorRef<Byte, Memory>{memory}};

      try {
        if (!runtime::readPrivateFile(directory, name, bytes, runtime::machines::MachineLimits::file_bytes)) {
          return std::nullopt;
        }
      } catch (const runtime::SystemError& error) {
        if (error.code() == EACCES || error.code() == ELOOP || error.code() == EISDIR) {
          throw InsecureProfileFile{};
        }

        throw;
      }

      return bytes;
    }

    class ProfileFileTransaction {
      friend class ProfileFile;

    public:
      ProfileFileTransaction(const ProfileFileTransaction&) = delete;
      ProfileFileTransaction& operator=(const ProfileFileTransaction&) = delete;
      ProfileFileTransaction(ProfileFileTransaction&&) noexcept = default;
      ProfileFileTransaction& operator=(ProfileFileTransaction&&) noexcept = default;
      ~ProfileFileTransaction() = default;

      template <Allocator Memory>
      [[nodiscard]] inline tbc::view<std::optional<Vector<Byte, Memory>>, tbc::lt::a> read(tbc::view<Memory&, tbc::lt::a> memory) const {
        return readProfileSource(memory, parent_.get(), name_.data());
      }

      void replace(std::string_view source) const;

    private:
      ProfileFileTransaction(runtime::FileDescriptor parent, runtime::FileDescriptor lock, std::string_view name);

      runtime::FileDescriptor parent_;
      runtime::FileDescriptor lock_;
      std::array<char, PathLimits::component_bytes + 1> name_{};
    };

    class ProfileFile {
    public:
      explicit ProfileFile(std::string_view path, std::stop_token stop = {});

      template <Allocator Memory>
      [[nodiscard]] inline tbc::view<std::optional<Vector<Byte, Memory>>, tbc::lt::a> read(tbc::view<Memory&, tbc::lt::a> memory) const {
        return readProfileSource(memory, AT_FDCWD, path());
      }

      [[nodiscard]] std::string_view path() const noexcept;
      [[nodiscard]] ProfileFileTransaction lock() const;

    private:
      std::array<char, PathLimits::path_bytes> path_{};
      std::size_t path_length_ = 0;
      std::size_t name_offset_ = 0;
      std::stop_token stop_;
    };

  }
}

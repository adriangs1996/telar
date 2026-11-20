// A file only its owner may read or replace, read whole and replaced atomically under a lock;
// the machine profiles live in one.
export module telar.gui.foundation.system:profile_file;

import std;
import telar.tbc;

import telar.gui.foundation.core;
import :path_limits;
import telar.platform.fs;
import telar.platform.primitives;
import telar.vocabulary;
import telar.base.memory.allocators;
import telar.base.ds;

export {
  namespace telar::gui::inline foundation::inline system {

    class InsecureProfileFile final : public std::runtime_error {
    public:
      InsecureProfileFile();
    };

    class ProfileFile;

    class ProfileOperationCancelled final : public std::exception {
    public:
      [[nodiscard]] const char* what() const noexcept override;
    };

    template <Allocator Memory>
    // The source bytes are allocated from memory, region `a`.
    [[nodiscard]] tbc::val_a<ds::Option<ds::Vec<Byte, Memory>>> readProfileSource(tbc::mut_a<Memory> memory, int directory, std::string_view name);

    class ProfileFileTransaction {
      friend class ProfileFile;

    public:
      ProfileFileTransaction(const ProfileFileTransaction&) = delete;
      ProfileFileTransaction& operator=(const ProfileFileTransaction&) = delete;
      ProfileFileTransaction(ProfileFileTransaction&&) noexcept = default;
      ProfileFileTransaction& operator=(ProfileFileTransaction&&) noexcept = default;
      ~ProfileFileTransaction() = default;

      template <Allocator Memory>
      [[nodiscard]] tbc::val_a<ds::Option<ds::Vec<Byte, Memory>>> read(tbc::mut_a<Memory> memory) const;

      void replace(std::string_view source) const;

    private:
      ProfileFileTransaction(runtime::FileDescriptor parent, runtime::FileDescriptor lock, std::string_view name);

      runtime::FileDescriptor parent_;
      runtime::FileDescriptor lock_;
      ds::Array<char, PathLimits::component_bytes + 1> name_{};
    };

    class ProfileFile {
    public:
      explicit ProfileFile(std::string_view path, std::stop_token stop = {});

      template <Allocator Memory>
      [[nodiscard]] tbc::val_a<ds::Option<ds::Vec<Byte, Memory>>> read(tbc::mut_a<Memory> memory) const;

      [[nodiscard]] std::string_view path() const noexcept;
      [[nodiscard]] ProfileFileTransaction lock() const;

    private:
      ds::Array<char, PathLimits::path_bytes> path_{};
      std::size_t path_length_ = 0;
      std::size_t name_offset_ = 0;
      std::stop_token stop_;
    };

    extern template tbc::val_a<ds::Option<ds::Vec<Byte, telar::Memory>>> readProfileSource<telar::Memory>(tbc::mut_a<telar::Memory> memory, int directory, std::string_view name);
    extern template tbc::val_a<ds::Option<ds::Vec<Byte, telar::ConcurrentMemory>>> readProfileSource<telar::ConcurrentMemory>(tbc::mut_a<telar::ConcurrentMemory> memory, int directory, std::string_view name);
    extern template tbc::val_a<ds::Option<ds::Vec<Byte, telar::Memory>>> ProfileFileTransaction::read<telar::Memory>(tbc::mut_a<telar::Memory> memory) const;
    extern template tbc::val_a<ds::Option<ds::Vec<Byte, telar::ConcurrentMemory>>> ProfileFileTransaction::read<telar::ConcurrentMemory>(tbc::mut_a<telar::ConcurrentMemory> memory) const;
    extern template tbc::val_a<ds::Option<ds::Vec<Byte, telar::Memory>>> ProfileFile::read<telar::Memory>(tbc::mut_a<telar::Memory> memory) const;
    extern template tbc::val_a<ds::Option<ds::Vec<Byte, telar::ConcurrentMemory>>> ProfileFile::read<telar::ConcurrentMemory>(tbc::mut_a<telar::ConcurrentMemory> memory) const;

  }
}

export module telar.gui.foundation.system:file_stamp;

import std;

export {
  namespace telar::gui::inline foundation::inline system {

    enum class FileSymlinks : std::uint8_t {
      follow,
      inspect,
    };

    struct FileStamp {
      std::uint64_t size = 0;
      std::int64_t modified_seconds = 0;
      std::int64_t modified_nanoseconds = 0;
      std::uint32_t kind = 0;

      bool operator==(const FileStamp&) const = default;

      [[nodiscard]] static std::optional<FileStamp> read(const char* path, FileSymlinks symlinks = FileSymlinks::follow) noexcept;
    };

  }
}

module telar.gui.foundation.system;

import std;

import telar.base.ds;
import telar.base.memory.allocators;

namespace telar::gui::inline foundation::inline system {

  namespace {

    constexpr std::string_view drag_prefix = "drag-";
    constexpr std::size_t drag_random_bytes = 8;
    constexpr std::size_t drag_name_bytes = drag_prefix.size() + (drag_random_bytes * 2);

    using DragName = ds::Array<char, drag_name_bytes>;

    // The name of one more drag's directory, which nothing else guesses.
    DragName dragName() noexcept {
      constexpr std::string_view digits = "0123456789abcdef";
      constexpr unsigned nibble_bits = 4;
      constexpr unsigned nibble_mask = 0xf;
      ds::Array<std::uint8_t, drag_random_bytes> random{};
      DragName name{};
      auto written = std::ranges::copy(drag_prefix, name.viewMut().begin()).out;

      SecureRandom::fill(random.viewMut());
      for (const auto byte : random) {
        *written++ = digits[byte >> nibble_bits];
        *written++ = digits[byte & nibble_mask];
      }

      return name;
    }

    // Removes the directories of the drags that are old at `now_seconds`.
    void sweepDragCache(const std::filesystem::path& root, std::uint64_t now_seconds) {
      std::error_code error;
      std::filesystem::directory_iterator entry{root, error};
      std::size_t seen = 0;

      for (; !error && entry != std::filesystem::directory_iterator{} && seen < DragCacheLimits::swept; entry.increment(error), ++seen) {
        std::error_code failed;
        const auto name = entry->path().filename().native();
        // A link is not followed: what it points at is not the cache's.
        const bool directory = entry->symlink_status(failed).type() == std::filesystem::file_type::directory;

        if (failed || !directory || !name.starts_with(drag_prefix)) {
          continue;
        }

        const auto written = std::filesystem::last_write_time(entry->path(), failed);

        if (failed) {
          continue;
        }

        const auto seconds = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::file_clock::to_sys(written).time_since_epoch()).count();
        const auto since = seconds < 0 ? std::uint64_t{0} : static_cast<std::uint64_t>(seconds);

        if (since < now_seconds && now_seconds - since > DragCacheLimits::kept_seconds) {
          std::filesystem::remove_all(entry->path(), failed);
        }
      }
    }

  }

  bool openDragCache(ds::String<Memory>& directory, std::string_view root, std::uint64_t now_seconds) {
    directory.clear();
    if (!root.starts_with('/') || root.contains('\0') || root.size() + 1 + drag_name_bytes >= PathLimits::path_bytes) {
      return false;
    }

    const std::filesystem::path base{root};
    std::error_code error;

    std::filesystem::create_directories(base, error);
    if (error || std::filesystem::symlink_status(base, error).type() != std::filesystem::file_type::directory || error) {
      return false;
    }

    std::filesystem::permissions(base, std::filesystem::perms::owner_all, error);
    if (error) {
      return false;
    }

    sweepDragCache(base, now_seconds);

    const auto name = dragName();
    const auto made = base / std::string_view{name.data(), name.size()};

    // A name that is taken is no directory of this drag's own.
    if (!std::filesystem::create_directory(made, error) || error) {
      return false;
    }

    std::filesystem::permissions(made, std::filesystem::perms::owner_all, error);
    if (error) {
      return false;
    }

    directory.assign(made.native());
    return true;
  }

}

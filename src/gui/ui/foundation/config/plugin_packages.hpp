#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application/dependencies.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_platform/file_descriptor.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include <QByteArrayView>
#include <QCryptographicHash>
#include <algorithm>
#include <array>
#include <cerrno>
#include <charconv>
#include <chrono>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <dirent.h>
#include <exception>
#include <fcntl.h>
#include <limits.h>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>

#pragma once

#include "application/dependencies.hpp"

import telar.plugins;

namespace telar::gui::qt {

  class PluginPackageHash {
  public:
    void update(std::string_view bytes) {
      hash_.addData(QByteArrayView{bytes.data(), static_cast<qsizetype>(bytes.size())});
    }

    [[nodiscard]] runtime::plugins::PackageDigest finish() const {
      runtime::plugins::PackageDigest result{};
      const auto bytes = hash_.resultView();

      std::ranges::copy(bytes, result.begin());

      return result;
    }

  private:
    QCryptographicHash hash_{QCryptographicHash::Sha256};
  };

  using PluginPackages = runtime::plugins::PackageRegistryStorage<ApplicationAllocator, runtime::plugins::PackageInspection<PluginPackageHash>>;

}

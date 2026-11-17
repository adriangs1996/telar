#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application/dependencies.hpp"
#include <QByteArrayView>
#include <QCryptographicHash>
#include <algorithm>
#include <cerrno>
#include <cstddef>
#include <fcntl.h>
#include <limits.h>
#include <string_view>

#pragma once

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

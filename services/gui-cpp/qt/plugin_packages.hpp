#pragma once

#include "application/dependencies.hpp"
#include "telar_plugins/package_inspection.hpp"
#include "telar_plugins/package_registry_storage.hpp"
#include <QByteArrayView>
#include <QCryptographicHash>
#include <algorithm>

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

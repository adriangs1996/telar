export module telar.gui.ui.kit.config:plugin_packages;

import std;
import telar.gui.qt;
import telar.plugins;
import telar.gui.foundation.core;

export namespace telar::gui::qt {

  class PluginPackageHash {
  public:
    [[tbc::hot_path]] inline void update(std::string_view bytes) {
      hash_.addData(QByteArrayView{bytes.data(), static_cast<qsizetype>(bytes.size())});
    }

    [[tbc::hot_path]] [[nodiscard]] inline runtime::plugins::PackageDigest finish() const {
      runtime::plugins::PackageDigest result{};
      const auto bytes = hash_.resultView();

      std::ranges::copy(bytes, result.viewMut().begin());

      return result;
    }

  private:
    QCryptographicHash hash_{QCryptographicHash::Sha256};
  };

  using PluginPackages = runtime::plugins::PackageRegistryStorage<ApplicationAllocator, runtime::plugins::PackageInspection<PluginPackageHash>>;

}

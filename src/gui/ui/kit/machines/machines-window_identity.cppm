export module telar.gui.ui.kit.machines:window_identity;

import std;
import telar.gui.qt;
import telar.wire.vocabulary;
import telar.base.ds;

export namespace telar::gui::qt {

  struct WindowIdentity {
    [[tbc::hot_path]] [[nodiscard]] inline static std::uint64_t remote(std::uint64_t window, std::string_view destination) {
      constexpr auto identity_namespace = ds::toArray("telar-gui-remote-window-v1");
      QCryptographicHash hash{QCryptographicHash::Sha256};

      hash.addData(QByteArrayView{identity_namespace.data(), static_cast<qsizetype>(identity_namespace.size())});
      ds::Array<Byte, sizeof(window)> identity{};
      std::span<Byte> output{identity.viewMut()};

      u64::encode(window, output);
      const auto identity_text = textView(identity);

      hash.addData(QByteArrayView{identity_text.data(), static_cast<qsizetype>(identity_text.size())});
      hash.addData(QByteArrayView{destination.data(), static_cast<qsizetype>(destination.size())});
      const auto digest = hash.result();
      auto prefix = byteView({digest.constData(), static_cast<std::size_t>(digest.size())}).first(sizeof(std::uint64_t));

      return u64::decode(prefix) | std::uint64_t{1};
    }
  };

}

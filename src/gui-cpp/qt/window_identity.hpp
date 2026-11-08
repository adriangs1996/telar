#pragma once

#include "telar_client/codecs/telar_wire.hpp"
#include <QByteArrayView>
#include <QCryptographicHash>
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>

namespace telar::gui::qt {

struct WindowIdentity {
  [[nodiscard]] static std::uint64_t remote(std::uint64_t window, std::string_view destination) {
    constexpr auto identity_namespace = std::to_array("telar-gui-remote-window-v1");
    QCryptographicHash hash{QCryptographicHash::Sha256};
    hash.addData(QByteArrayView{identity_namespace.data(), static_cast<qsizetype>(identity_namespace.size())});
    std::array<Byte, sizeof(window)> identity{};
    std::span<Byte> output{identity};
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

#pragma once

#include "http2/frame.hpp"
#include <string>
#include <string_view>
#include <span>
#include <memory>
#include <vector>
#include <nghttp2/nghttp2.h>
#include "check.hpp"

inline std::string hpackFields(std::span<const std::pair<std::string_view, std::string_view>> fields) {
  nghttp2_hd_deflater *raw = nullptr;
  constexpr std::size_t table_bytes = 4096;
  check(nghttp2_hd_deflate_new(&raw, table_bytes) == 0);
  const auto encoder = std::unique_ptr<nghttp2_hd_deflater, decltype(&nghttp2_hd_deflate_del)>{raw, &nghttp2_hd_deflate_del};
  std::vector<nghttp2_nv> native;
  for (const auto &[name, value] : fields) {
    native.push_back({reinterpret_cast<std::uint8_t *>(const_cast<char *>(name.data())), reinterpret_cast<std::uint8_t *>(const_cast<char *>(value.data())), name.size(), value.size(), NGHTTP2_NV_FLAG_NONE});
  }
  std::string output(nghttp2_hd_deflate_bound(encoder.get(), native.data(), native.size()), '\0');
  const auto size = nghttp2_hd_deflate_hd(encoder.get(), reinterpret_cast<std::uint8_t *>(output.data()), output.size(), native.data(), native.size());
  check(size >= 0);
  output.resize(static_cast<std::size_t>(size));
  return output;
}

inline std::string http2Frame(telar::runtime::Http2FrameKind kind, std::uint8_t flags, std::uint32_t stream, std::string_view payload) {
  const auto length = payload.size();
  std::string bytes{
      static_cast<char>(length >> 16),
      static_cast<char>(length >> 8),
      static_cast<char>(length),
      static_cast<char>(kind),
      static_cast<char>(flags),
      static_cast<char>(stream >> 24),
      static_cast<char>(stream >> 16),
      static_cast<char>(stream >> 8),
      static_cast<char>(stream),
  };
  bytes.append(payload);
  return bytes;
}

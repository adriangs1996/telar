#pragma once

#include "../platform/private_file.hpp"
#include "../text/hexadecimal.hpp"
#include "manifest.hpp"

namespace telar::runtime::plugins {

struct TrustGrant {
  FixedText<PackageLimits::id_bytes> plugin;
  PackageDigest digest{};
  Capabilities capabilities;
};

class TrustStore {
public:
  std::span<const TrustGrant> grants() const noexcept {
    return std::span{grants_}.first(count_);
  }

  template <Allocator Memory>
  static TrustStore load(Memory &memory, std::string_view path) {
    Vector<unsigned char, Memory> bytes{AllocatorRef<unsigned char, Memory>{memory}};
    if (!readPrivateFile(AT_FDCWD, path, bytes, PackageLimits::trust_bytes - 1)) {
      return {};
    }
    return parse(memory, {reinterpret_cast<const char *>(bytes.data()), bytes.size()});
  }

  template <Allocator Memory>
  static TrustStore parse(Memory &memory, std::string_view bytes) {
    validateUtf8(bytes);
    JsonFields root{memory, JsonValue::parse(bytes), root_fields};
    if (!SchemaVersion<Memory>::isOne(memory, root.required("version"))) {
      throw std::invalid_argument{"Incompatible plugin trust store"};
    }

    TrustStore store;
    root.required("grants").eachElement([&](const JsonValue &value) {
      if (store.count_ == PackageLimits::grants) {
        throw std::invalid_argument{"Too many plugin trust grants"};
      }
      JsonFields fields{memory, value, grant_fields};
      auto &grant = store.grants_[store.count_];
      grant.plugin.assign(fields.string("plugin"));
      if (!validIdentifier(grant.plugin.view())) {
        throw std::invalid_argument{"Invalid trusted plugin ID"};
      }
      for (const auto &existing : std::span{store.grants_}.first(store.count_)) {
        if (existing.plugin.view() == grant.plugin.view()) {
          throw std::invalid_argument{"Duplicate plugin trust grant"};
        }
      }
      grant.digest = parseDigest(fields.string("digest"));
      grant.capabilities = Capabilities::parse(memory, fields.required("capabilities"));
      ++store.count_;
    });
    return store;
  }

  Capabilities granted(std::string_view id, const PackageDigest &digest) const noexcept {
    for (const auto &grant : std::span{grants_}.first(count_)) {
      if (stableId(grant.plugin.view()) == stableId(id) && grant.digest == digest) {
        return grant.capabilities;
      }
    }
    return {};
  }

  void upsert(const Manifest &manifest, const PackageDigest &digest, Capabilities capabilities) {
    for (auto &entry : std::span{grants_}.first(count_)) {
      if (entry.plugin.view() == manifest.id.view()) {
        entry.digest = digest;
        entry.capabilities = capabilities;
        return;
      }
    }
    if (count_ == grants_.size()) {
      throw std::invalid_argument{"Too many plugin trust grants"};
    }

    auto &entry = grants_[count_++];
    entry.plugin = manifest.id;
    entry.digest = digest;
    entry.capabilities = capabilities;
  }

  bool revoke(std::string_view id) {
    if (!validIdentifier(id)) { throw std::invalid_argument{"Invalid plugin ID"}; }
    for (std::size_t index = 0; index < count_; ++index) {
      if (grants_[index].plugin.view() != id) { continue; }
      for (std::size_t next = index + 1; next < count_; ++next) { grants_[next - 1] = grants_[next]; }
      --count_;
      return true;
    }
    return false;
  }

  template <Allocator Memory>
  String<Memory> json(Memory &memory) const {
    String<Memory> output{"{\"version\":1,\"grants\":[", AllocatorRef<char, Memory>{memory}};
    for (std::size_t index = 0; index < count_; ++index) {
      if (index != 0) {
        output += ',';
      }
      const auto &entry = grants_[index];
      output += "{\"plugin\":";
      appendJsonString(output, entry.plugin.view());
      output += ",\"digest\":\"";
      appendLowerHex(output, entry.digest);
      output += "\",\"capabilities\":[";
      bool first = true;
      for (unsigned value = 0; value < static_cast<unsigned>(Capability::count); ++value) {
        const auto capability = static_cast<Capability>(value);
        if (entry.capabilities.contains(capability)) {
          if (!first) {
            output += ',';
          }
          appendJsonString(output, Capabilities::name(capability));
          first = false;
        }
      }
      output += "]}";
    }
    output += "]}\n";
    if (output.size() > PackageLimits::trust_bytes) {
      throw std::length_error{"Plugin trust store exceeds its limit"};
    }
    return output;
  }

  static PackageDigest parseDigest(std::string_view text) {
    PackageDigest digest;
    if (text.size() != digest.size() * 2) {
      throw std::invalid_argument{"Invalid plugin digest"};
    }
    for (std::size_t index = 0; index < digest.size(); ++index) {
      digest[index] = static_cast<std::uint8_t>((hex(text[2 * index]) << 4) | hex(text[2 * index + 1]));
    }
    return digest;
  }

private:
  static unsigned hex(char byte) {
    if (byte >= '0' && byte <= '9') {
      return static_cast<unsigned>(byte - '0');
    }
    if (byte >= 'a' && byte <= 'f') {
      return static_cast<unsigned>(byte - 'a' + 10);
    }
    if (byte >= 'A' && byte <= 'F') {
      return static_cast<unsigned>(byte - 'A' + 10);
    }
    throw std::invalid_argument{"Invalid plugin digest"};
  }

  static constexpr auto root_fields = std::to_array<std::string_view>({"version", "grants"});
  static constexpr auto grant_fields = std::to_array<std::string_view>({"plugin", "digest", "capabilities"});
  std::array<TrustGrant, PackageLimits::grants> grants_;
  std::size_t count_ = 0;
};

}

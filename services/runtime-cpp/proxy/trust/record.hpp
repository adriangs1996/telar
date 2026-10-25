#pragma once

#include "../../memory/fixed_text.hpp"
#include "../../platform/private_file.hpp"
#include "../../platform/write_private_file.hpp"
#include "../../text/json_fields.hpp"
#include "../../text/schema_version.hpp"
#include "../../text/utf8.hpp"

namespace telar::runtime::proxy_trust {

enum class Backend { macos,
                     update_ca_certificates,
                     trust };

inline std::string_view backendName(Backend backend) noexcept {
  switch (backend) {
  case Backend::macos:
    return "macos";
  case Backend::update_ca_certificates:
    return "update-ca-certificates";
  case Backend::trust:
    return "trust";
  }

  std::unreachable();
}

struct Record {
  static constexpr std::string_view filename = "trust-install.json";
  static constexpr std::size_t maximum_bytes = 4096;

  Backend backend = Backend::macos;
  std::array<char, 40> fingerprint;
  FixedText<PATH_MAX> store;

  template <Allocator Memory>
  static Record parse(Memory &memory, std::string_view source) {
    validateUtf8(source);
    constexpr auto names = std::to_array<std::string_view>({"version", "backend", "fingerprint", "store_path"});
    JsonFields fields{memory, JsonValue::parse(source), names};
    if (!SchemaVersion<Memory>::isOne(memory, fields.required("version"))) {
      throw std::invalid_argument{"Invalid proxy trust record version"};
    }

    Record record;
    const auto backend = fields.string("backend");
    if (backend == "macos") {
      record.backend = Backend::macos;
    } else if (backend == "update-ca-certificates") {
      record.backend = Backend::update_ca_certificates;
    } else if (backend == "trust") {
      record.backend = Backend::trust;
    } else {
      throw std::invalid_argument{"Invalid proxy trust backend"};
    }

    const auto fingerprint = fields.string("fingerprint");
    if (fingerprint.size() != record.fingerprint.size()) {
      throw std::invalid_argument{"Invalid proxy trust fingerprint"};
    }
    for (std::size_t index = 0; index < fingerprint.size(); ++index) {
      const char byte = fingerprint[index];
      if (byte >= 'a' && byte <= 'f') {
        record.fingerprint[index] = byte - 'a' + 'A';
      } else if ((byte >= 'A' && byte <= 'F') || (byte >= '0' && byte <= '9')) {
        record.fingerprint[index] = byte;
      } else {
        throw std::invalid_argument{"Invalid proxy trust fingerprint"};
      }
    }

    const auto store = fields.string("store_path");
    if (store.empty() || store.front() != '/' || store.contains('\0')) {
      throw std::invalid_argument{"Invalid proxy trust store path"};
    }

    record.store.assign(store);
    return record;
  }

  template <Allocator Memory>
  static std::optional<Record> read(Memory &memory, int directory) {
    Vector<unsigned char, Memory> source{AllocatorRef<unsigned char, Memory>{memory}};
    if (!readPrivateFile(directory, filename, source, maximum_bytes - 1)) {
      return std::nullopt;
    }

    return parse(memory, {reinterpret_cast<const char *>(source.data()), source.size()});
  }

  template <Allocator Memory>
  void write(Memory &memory, int directory) const {
    String<Memory> source{"{\n  \"version\": 1,\n  \"backend\": ", AllocatorRef<char, Memory>{memory}};
    appendJsonString(source, backendName(backend));
    source += ",\n  \"fingerprint\": ";
    appendJsonString(source, {fingerprint.data(), fingerprint.size()});
    source += ",\n  \"store_path\": ";
    appendJsonString(source, store.view());
    source += "\n}\n";
    if (source.size() > maximum_bytes) {
      throw std::length_error{"Proxy trust record exceeds its bound"};
    }
    if (const int error = writePrivateFile(directory, filename, {reinterpret_cast<const unsigned char *>(source.data()), source.size()}, PrivateFileMode::replace)) {
      throw SystemError{"Publish proxy trust record", error};
    }
  }
};

}

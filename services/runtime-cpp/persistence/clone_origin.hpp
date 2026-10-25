#pragma once

#include "../text/json.hpp"
#include "reader.hpp"

namespace telar::runtime::checkpoint {

enum CloneOriginField : unsigned {
  version_field = 1,
  source_socket_field = 2,
  workspaces_field = 4
};

template <Allocator Memory>
bool matchingCloneOrigin(Memory &memory, std::span<const Byte> bytes, std::string_view source_socket) {
  const auto document = JsonValue::parse({reinterpret_cast<const char *>(bytes.data()), bytes.size()});
  String<Memory> key{AllocatorRef<char, Memory>{memory}};
  String<Memory> value{AllocatorRef<char, Memory>{memory}};
  unsigned seen = 0;
  bool matching = false;
  document.eachMember([&](const JsonValue &name, const JsonValue &field) {
    name.string(key);
    CloneOriginField bit;
    if (key == "version") {
      bit = version_field;
      if (field.encoded() != "1") {
        throw EncodingError{"Unsupported clone origin version"};
      }
    } else if (key == "source_socket") {
      bit = source_socket_field;
      field.string(value);
      matching = value == source_socket;
    } else if (key == "workspaces") {
      bit = workspaces_field;
      field.eachElement([&](const JsonValue &element) { element.string(value); });
    } else {
      throw EncodingError{"Unknown clone origin field"};
    }
    if ((seen & bit) != 0) {
      throw EncodingError{"Duplicate clone origin field"};
    }
    seen |= bit;
  });
  constexpr unsigned required = source_socket_field | workspaces_field;
  if ((seen & required) != required) {
    throw EncodingError{"Incomplete clone origin"};
  }
  return matching;
}

template <Allocator Memory>
String<Memory> encodeCloneOrigin(Memory &memory, std::span<const Byte> checkpoint, std::string_view source_socket) {
  String<Memory> origin{AllocatorRef<char, Memory>{memory}};
  origin = "{\"version\":1,\"source_socket\":";
  appendJsonString(origin, source_socket);
  origin += ",\"workspaces\":[";
  bool first = true;
  Reader reader{checkpoint};
  reader.read([&]<typename Record>(const Record &record) {
    if constexpr (std::same_as<Record, WorkspaceRecord>) {
      if (!first) {
        origin.push_back(',');
      }
      first = false;
      std::array<char, 20> identity;
      const auto converted = std::to_chars(identity.data(), identity.data() + identity.size(), record.id);
      appendJsonString(origin, {identity.data(), converted.ptr});
    }
  });
  origin += "]}";
  return origin;
}

}

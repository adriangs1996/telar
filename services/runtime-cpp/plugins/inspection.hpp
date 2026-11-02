#pragma once

#include "../text/hexadecimal.hpp"
#include "package.hpp"

namespace telar::runtime::plugins {

template <Allocator Memory>
void appendInspection(String<Memory> &output, const Package &package) {
  const auto &manifest = package.manifest;
  output += "id: ";
  output += manifest.id.view();
  output += "\nversion: ";
  output += manifest.version.view();
  output += "\nsource: ";
  output += manifest.source.view();
  output += "\nrevision: ";
  output += manifest.revision.view();
  output += "\ndigest: ";
  appendLowerHex(output, package.digest);
  output += "\nactions:";
  for (const auto &action : std::span{manifest.actions}.first(manifest.action_count)) {
    output += ' ';
    output += action.view();
  }
  output += "\ncapabilities:";
  for (unsigned index = 0; index < static_cast<unsigned>(Capability::count); ++index) {
    const auto capability = static_cast<Capability>(index);
    if (manifest.capabilities.contains(capability)) {
      output += ' ';
      output += Capabilities::name(capability);
    }
  }
  output += '\n';
}

}

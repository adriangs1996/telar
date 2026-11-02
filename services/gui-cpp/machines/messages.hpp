#pragma once

#include "failure.hpp"
#include <string_view>

namespace telar::gui {

struct MachineProfileMessages {
  static constexpr std::string_view insecure_file = "machines.json must be a regular file only its owner can read and write (chmod 600)";
  static constexpr std::string_view edit_pending = "the previous machine change is still being saved";

  [[nodiscard]] static std::string_view failure(MachineError error) {
    switch (error) {
    case MachineError::unknown_machine:
      return "no saved machine has that label; see `telar machine list`";
    case MachineError::duplicate_label:
      return "that label is already taken, by a saved machine or by this machine";
    case MachineError::duplicate_destination:
      return "two saved machines cannot share one SSH destination";
    case MachineError::too_many:
      return "machines.json already holds the most machines it can";
    case MachineError::invalid_label:
      return "labels are 1 to 32 letters, digits, '.', '_' or '-', starting with a letter or a digit";
    case MachineError::invalid_color:
      return "colors are #RRGGBB or a theme role such as red or accent";
    case MachineError::invalid_destination:
      return "destinations are an ssh host alias or user@host, without spaces or a leading '-'";
    case MachineError::invalid_program:
      return "telar paths are absolute and hold only letters, digits, '/', '.', '_', '+' or '-'";
    case MachineError::invalid_profiles:
      return "machines.json is not a file this telar can read";
    case MachineError::incompatible_profiles:
      return "machines.json was written by a newer telar; update this one to read it";
    default:
      return MachineFailure::name(error);
    }
  }
};

}

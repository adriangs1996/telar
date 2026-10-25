#pragma once

#include "input_scanner.hpp"

namespace telar::runtime {

class OscScanner {
public:
  enum class Event {
    none,
    start,
    payload,
    end
  };

  Event next(std::uint8_t byte) noexcept {
    const auto control = static_cast<ControlByte>(byte);
    switch (state_) {
    case State::ground:
      if (control == ControlByte::escape) {
        state_ = State::escape;
      }
      return Event::none;
    case State::escape:
      if (byte == ']') {
        state_ = State::osc;
        return Event::start;
      }
      state_ = State::ground;
      return Event::none;
    case State::osc:
      if (control == ControlByte::bell) {
        state_ = State::ground;
        return Event::end;
      }
      if (control == ControlByte::escape) {
        state_ = State::osc_escape;
        return Event::none;
      }
      return Event::payload;
    case State::osc_escape:
      if (byte == '\\') {
        state_ = State::ground;
        return Event::end;
      }
      state_ = control == ControlByte::escape ? State::escape : State::ground;
      return Event::none;
    }

    return Event::none;
  }

private:
  enum class State {
    ground,
    escape,
    osc,
    osc_escape
  };
  State state_ = State::ground;
};

}

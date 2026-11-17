export module telar.gui.foundation.drawing:modal_motion;

import std;

// Interface: presentation/modal_motion.cppm
export {
  namespace telar::gui::inline foundation::inline drawing {

    class ModalMotion {
    public:
      static constexpr std::uint64_t duration_ns = 220'000'000;

      [[nodiscard]] float sample(std::optional<std::uint64_t> generation, std::optional<std::uint64_t> timestamp) noexcept;
      [[nodiscard]] std::optional<std::uint64_t> deadline(std::uint64_t now_ns, std::uint64_t interval_ns) const noexcept;

    private:
      [[nodiscard]] static std::uint64_t add(std::uint64_t left, std::uint64_t right) noexcept;

      std::optional<std::uint64_t> generation_;
      std::optional<std::uint64_t> started_ns_;
    };

  }
}

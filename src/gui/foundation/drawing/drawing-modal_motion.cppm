export module telar.gui.foundation.drawing:modal_motion;

import std;
import telar.base.ds;

// Interface: presentation/modal_motion.cppm
export {
  namespace telar::gui::inline foundation::inline drawing {

    class ModalMotion {
    public:
      static constexpr std::uint64_t duration_ns = 220'000'000;

      [[nodiscard]] float sample(ds::Option<std::uint64_t> generation, ds::Option<std::uint64_t> timestamp) noexcept;
      [[nodiscard]] ds::Option<std::uint64_t> deadline(std::uint64_t now_ns, std::uint64_t interval_ns) const noexcept;

    private:
      [[nodiscard]] static std::uint64_t add(std::uint64_t left, std::uint64_t right) noexcept;

      ds::Option<std::uint64_t> generation_;
      ds::Option<std::uint64_t> started_ns_;
    };

  }
}

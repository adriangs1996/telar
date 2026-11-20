module telar.vocabulary;

// The header declares RequestError in the global module, so its definitions belong to it too.
extern "C++" {
namespace telar::runtime {

  const char* RequestError::what() const noexcept {
    return message_;
  }

}
}

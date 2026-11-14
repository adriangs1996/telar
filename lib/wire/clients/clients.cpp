module telar.wire.clients;

import std;
import telar.wire.vocabulary;

// The owned header declares these in the global module, so their definitions belong to it too.
extern "C++" {
namespace telar {

  void ClientList::validate() const {
    for (std::size_t i = 0; i < entries.size(); ++i) {
      for (std::size_t j = 0; j < i; ++j) {
        if (entries[i].id == entries[j].id) {
          throw EncodingError{"Duplicate client identity"};
        }
      }
    }
  }

}
}

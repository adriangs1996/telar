# The use cases of the GUI, a domain each: a feature imports only foundation, never another
# feature.
foreach(feature IN ITEMS peek palette)
  add_subdirectory(${feature})
endforeach()

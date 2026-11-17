# The use cases of the GUI, a domain each: a feature imports only foundation, never another
# feature.
foreach(feature IN ITEMS peek palette paths history prompt terminal/input terminal/links terminal/copy_mode terminal/graphics terminal/attachments window status_bar notifications)
  add_subdirectory(${feature})
endforeach()

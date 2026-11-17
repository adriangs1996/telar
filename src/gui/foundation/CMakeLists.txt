# The vocabulary of the GUI, lowest first: each folder is a module and a domain that imports only
# the ones before it.
foreach(module IN ITEMS core system text terminal fonts)
  add_subdirectory(${module})
endforeach()

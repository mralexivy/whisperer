cmake_minimum_required(VERSION 3.20)
project(WhispererAudio LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(ASPL "${CMAKE_CURRENT_SOURCE_DIR}/../../../Vendor/libASPL")
file(GLOB ASPL_SOURCES CONFIGURE_DEPENDS "${ASPL}/src/*.cpp")
add_library(WhispererASPL STATIC ${ASPL_SOURCES})
target_include_directories(WhispererASPL PUBLIC "${ASPL}/include")
target_compile_options(WhispererASPL PRIVATE -Wno-invalid-offsetof)
target_link_libraries(WhispererASPL PUBLIC "-framework CoreFoundation")
add_library(WhispererAudio MODULE Driver.cpp)
target_link_libraries(WhispererAudio PRIVATE WhispererASPL "-framework CoreAudio")
set_target_properties(WhispererAudio PROPERTIES BUNDLE TRUE BUNDLE_EXTENSION driver PREFIX "" SUFFIX ""
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in")
add_custom_command(TARGET WhispererAudio POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_DIR:WhispererAudio>/Contents/Resources"
  COMMAND ${CMAKE_COMMAND} -E copy "${ASPL}/LICENSE" "$<TARGET_BUNDLE_DIR:WhispererAudio>/Contents/Resources/libASPL-LICENSE")

# CMake toolchain for zephyr and the engine on iOS (arm64), against the dependency prefix built by
# deps/build_deps.sh. Environment (also seen by try_compile, which re-reads this file):
#   ZIOS_PREFIX    the dependency prefix of deps/build_deps.sh
#   ZIOS_PLATFORM  iphoneos (devices) or iphonesimulator
#   ZIOS_MIN_IOS   deployment target, e.g. 15.0
set(_zios_prefix "$ENV{ZIOS_PREFIX}")
set(_zios_platform "$ENV{ZIOS_PLATFORM}")
set(_zios_min "$ENV{ZIOS_MIN_IOS}")
if(NOT _zios_prefix)
  message(FATAL_ERROR "ZIOS_PREFIX is not set")
endif()
if(NOT _zios_platform)
  set(_zios_platform iphoneos)
endif()
if(NOT _zios_min)
  set(_zios_min 15.0)
endif()

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_SYSROOT ${_zios_platform})
set(CMAKE_OSX_DEPLOYMENT_TARGET ${_zios_min})
set(CMAKE_MACOSX_BUNDLE OFF)
set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)

# what zephyr's own depends toolchain sets for a cross build
set(STATIC ON)
set(UNBOUND_STATIC ON)
set(ARCH "default")
set(BUILD_64 ON)
set(BUILD_TAG "ios-armv8")
set(DEPENDS true)
set(BREW OFF)
set(PORT OFF)

set(CMAKE_FIND_ROOT_PATH ${_zios_prefix})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_FIND_FRAMEWORK NEVER)
set(ENV{PKG_CONFIG_PATH} ${_zios_prefix}/lib/pkgconfig)

set(UNBOUND_INCLUDE_DIR ${_zios_prefix}/include)
set(UNBOUND_LIBRARIES ${_zios_prefix}/lib/libunbound.a)
set(ZMQ_INCLUDE_PATH ${_zios_prefix}/include)
set(ZMQ_LIB ${_zios_prefix}/lib/libzmq.a)

# Boost: zephyr uses FindBoost (CMP0167 OLD); static archives (--layout=system) against the
# shared C++ runtime
set(Boost_NO_BOOST_CMAKE ON)
set(Boost_IGNORE_SYSTEM_PATH ON)
set(Boost_NO_SYSTEM_PATHS ON)
set(BOOST_ROOT ${_zios_prefix})
set(BOOST_INCLUDEDIR ${_zios_prefix}/include)
set(BOOST_LIBRARYDIR ${_zios_prefix}/lib)
set(Boost_USE_STATIC_LIBS ON)
set(Boost_USE_STATIC_RUNTIME OFF)
set(Boost_USE_MULTITHREADED ON)
set(CMAKE_POLICY_DEFAULT_CMP0167 OLD)

set(OPENSSL_ROOT_DIR ${_zios_prefix})
set(OPENSSL_USE_STATIC_LIBS ON)
set(SODIUM_LIBRARY ${_zios_prefix}/lib/libsodium.a)

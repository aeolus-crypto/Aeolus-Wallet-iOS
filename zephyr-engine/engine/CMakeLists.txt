# The iOS engine: zephyr-cpp's wallet sources plus the C interface (zephyr_ios.cpp), as a static
# library over zephyr's static libraries (zephyr-cpp and zephyr are separate trees); scripts/build_engine.sh merges everything into one
# archive and links the smoke test against it.
cmake_minimum_required(VERSION 3.16)
project(zephyr_ios C CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(ZEPHYR_CPP "" CACHE PATH "zephyr-cpp source directory")
set(ZEPHYR_SRC "" CACHE PATH "zephyr source directory")
set(ZEPHYR_BUILD "" CACHE PATH "zephyr build directory (scripts/build_zephyr.sh)")
set(ZIOS_SOURCES "unknown" CACHE STRING "description of the pinned sources")
set(MONERO_PROJECT "${ZEPHYR_SRC}")
set(MONERO_PROJECT_SRC "${MONERO_PROJECT}/src")

find_package(Boost 1.58 REQUIRED COMPONENTS chrono date_time filesystem program_options regex serialization wserialization system thread)
find_package(OpenSSL REQUIRED)

add_library(zephyr_engine STATIC
  zephyr_ios.cpp
  zephyr_ios_wallet.cpp
  ${ZEPHYR_CPP}/src/utils/gen_utils.cpp
  ${ZEPHYR_CPP}/src/utils/monero_utils.cpp
  ${ZEPHYR_CPP}/src/daemon/monero_daemon_model.cpp
  ${ZEPHYR_CPP}/src/daemon/monero_daemon.cpp
  ${ZEPHYR_CPP}/src/wallet/monero_wallet_model.cpp
  ${ZEPHYR_CPP}/src/wallet/monero_wallet_keys.cpp
  ${ZEPHYR_CPP}/src/wallet/monero_wallet_full.cpp
)
target_compile_definitions(zephyr_engine PRIVATE ZIOS_SOURCES="${ZIOS_SOURCES}")
# zephyr-cpp's monero_wallet_model.h uses std::map without including <map> (as in myzephyr-java)
target_compile_options(zephyr_engine PRIVATE -include map -fvisibility=hidden -fvisibility-inlines-hidden)
target_include_directories(zephyr_engine PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${ZEPHYR_CPP}/src
  ${ZEPHYR_CPP}/external/libsodium/include/sodium
  ${MONERO_PROJECT}/contrib/epee/include
  ${MONERO_PROJECT}/external
  ${MONERO_PROJECT}/external/easylogging++
  ${MONERO_PROJECT}/external/rapidjson/include
  ${MONERO_PROJECT_SRC}
  ${MONERO_PROJECT_SRC}/crypto
  ${MONERO_PROJECT_SRC}/crypto/crypto_ops_builder/include
  ${MONERO_PROJECT_SRC}/wallet
  ${MONERO_PROJECT_SRC}/wallet/api
  ${MONERO_PROJECT_SRC}/hardforks
  ${ZEPHYR_BUILD}/generated_include
  ${ZEPHYR_BUILD}/translations
  ${Boost_INCLUDE_DIRS}
  ${OPENSSL_INCLUDE_DIR}
)

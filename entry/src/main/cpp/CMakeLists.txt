# Native layer of the Opus codec sample.
#
# The ArkTS side has no Opus binding (media.CodecMimeType exposes AAC/FLAC/MP3/...
# but not Opus), so the codec itself is driven through the AVCodec NDK
# (OH_AudioCodec_* + OH_AVCODEC_MIMETYPE_AUDIO_OPUS) and surfaced to ArkTS as a
# small NAPI module named "opuscodec".
cmake_minimum_required(VERSION 3.5.0)
project(how_to_use_opuscodec)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include_directories(${NATIVERENDER_ROOT_PATH})

add_library(opuscodec SHARED
    opus_session.cpp
    napi_init.cpp)

target_link_libraries(opuscodec PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_media_core.so
    libnative_media_codecbase.so
    libnative_media_acodec.so)

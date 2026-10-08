/**
 * Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * Thin RAII wrapper around one OH_AVCodec instance configured for
 * OH_AVCODEC_MIMETYPE_AUDIO_OPUS ("audio/opus").
 *
 * The AVCodec NDK is fully asynchronous: input buffers are handed to us through
 * OH_AVCodecOnNeedInputBuffer and encoded/decoded frames arrive through
 * OH_AVCodecOnNewOutputBuffer, both on codec-owned threads. OpusSession keeps a
 * queue of the currently available input buffers so that a real-time producer
 * (the microphone callback) can push a 20 ms frame without ever blocking, and
 * forwards every output frame to an OutputHandler.
 */
#ifndef HOW_TO_USE_OPUSCODEC_OPUS_SESSION_H
#define HOW_TO_USE_OPUSCODEC_OPUS_SESSION_H

#include <atomic>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avcodec_audiocodec.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avformat.h>

namespace opusdemo {

struct OpusConfig {
    bool isEncoder = true;
    int32_t sampleRate = 16000;   // Opus accepts 8k / 12k / 16k / 24k / 48k
    int32_t channelCount = 1;
    int32_t bitrate = 24000;      // encoder only
    int32_t complexity = 5;       // OH_MD_KEY_AUDIO_COMPRESSION_LEVEL, 0..10
    int32_t frameSizeMs = 20;     // frame length the pipeline feeds the codec
};

/** One codec output frame, already copied out of the codec-owned buffer. */
struct CodecOutput {
    std::vector<uint8_t> data;
    int64_t pts = 0;
    uint32_t flags = 0;
    double latencyMs = 0.0;   // push -> output round trip inside the codec
    int32_t errorCode = 0;    // != 0 means this record carries an error only
};

using OutputHandler = std::function<void(std::unique_ptr<CodecOutput>)>;

struct OpusStats {
    uint64_t inFrames = 0;
    uint64_t outFrames = 0;
    uint64_t inBytes = 0;
    uint64_t outBytes = 0;
    uint64_t dropped = 0;      // frames rejected because no input buffer was free
    double lastLatencyMs = 0.0;
    double avgLatencyMs = 0.0;
    double maxLatencyMs = 0.0;
};

/** Runtime capability of the Opus encoder/decoder present on this device. */
struct OpusCapability {
    bool supported = false;
    bool isHardware = false;
    std::string name;
    std::vector<int32_t> sampleRates;
    int32_t channelMin = 0;
    int32_t channelMax = 0;
    int32_t bitrateMin = 0;
    int32_t bitrateMax = 0;
    int32_t complexityMin = 0;
    int32_t complexityMax = 0;
};

OpusCapability QueryCapability(bool isEncoder);

class OpusSession {
public:
    static std::shared_ptr<OpusSession> Create(const OpusConfig &config, std::string &message);
    ~OpusSession();

    OpusSession(const OpusSession &) = delete;
    OpusSession &operator=(const OpusSession &) = delete;

    bool Start(std::string &message);
    /** Non blocking. Returns false when every input buffer is still in flight. */
    bool Push(const uint8_t *data, size_t size, int64_t ptsUs, uint32_t flags);
    void Flush();
    void Stop();
    void SetOutputHandler(OutputHandler handler);

    OpusStats GetStats() const;
    const OpusConfig &Config() const { return config_; }
    const std::string &CodecName() const { return codecName_; }
    const std::string &ConfigNote() const { return configNote_; }
    /** PCM bytes of one frame; the natural push size for the encoder. */
    int32_t FrameBytes() const;

private:
    explicit OpusSession(const OpusConfig &config) : config_(config) {}

    static void OnError(OH_AVCodec *codec, int32_t errorCode, void *userData);
    static void OnStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData);
    static void OnNeedInputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData);
    static void OnNewOutputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData);

    OH_AVFormat *BuildFormat(bool withIdentificationHeader) const;
    void Dispatch(std::unique_ptr<CodecOutput> output);

    OpusConfig config_;
    OH_AVCodec *codec_ = nullptr;
    std::string codecName_;
    std::string configNote_;

    mutable std::mutex mutex_;
    std::deque<std::pair<uint32_t, OH_AVBuffer *>> freeInputs_;
    std::unordered_map<int64_t, int64_t> pushTimeNs_;   // pts -> steady clock ns
    OpusStats stats_;
    bool running_ = false;

    std::mutex handlerMutex_;
    OutputHandler handler_;
};

}  // namespace opusdemo

#endif  // HOW_TO_USE_OPUSCODEC_OPUS_SESSION_H

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

#include "opus_session.h"

#include <algorithm>
#include <chrono>

#include <hilog/log.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_averrors.h>

namespace opusdemo {
namespace {

constexpr int32_t BYTES_PER_SAMPLE = 2;   // SAMPLE_S16LE
constexpr size_t OPUS_HEAD_SIZE = 19;
constexpr uint16_t OPUS_PRE_SKIP = 312;   // libopus lookahead at 48 kHz (6.5 ms)

// hilog/log.h already defines LOG_DOMAIN and LOG_TAG as macros, so the values
// are passed to OH_LOG_Print directly.
#define OPUS_LOG_DOMAIN 0x3200
#define OPUS_LOG_TAG "OpusCodec"
#define OPUS_LOGI(...) ((void)OH_LOG_Print(LOG_APP, LOG_INFO, OPUS_LOG_DOMAIN, OPUS_LOG_TAG, __VA_ARGS__))
#define OPUS_LOGE(...) ((void)OH_LOG_Print(LOG_APP, LOG_ERROR, OPUS_LOG_DOMAIN, OPUS_LOG_TAG, __VA_ARGS__))

int64_t NowNs()
{
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

/*
 * Identification header (OpusHead) as defined by RFC 7845. A decoder fed by a
 * demuxer normally receives it from the container; here the stream is raw
 * packets, so we synthesise it and hand it over through
 * OH_MD_KEY_IDENTIFICATION_HEADER. Devices whose Opus decoder does not expect
 * that key fall back to the plain configuration, see Create().
 */
std::vector<uint8_t> BuildOpusHead(int32_t channelCount, int32_t sampleRate)
{
    std::vector<uint8_t> head(OPUS_HEAD_SIZE, 0);
    const char magic[] = "OpusHead";
    std::copy_n(magic, 8, head.begin());
    head[8] = 1;                                              // version
    head[9] = static_cast<uint8_t>(channelCount);             // channel count
    head[10] = static_cast<uint8_t>(OPUS_PRE_SKIP & 0xFF);    // pre-skip, little endian
    head[11] = static_cast<uint8_t>((OPUS_PRE_SKIP >> 8) & 0xFF);
    head[12] = static_cast<uint8_t>(sampleRate & 0xFF);       // original sample rate
    head[13] = static_cast<uint8_t>((sampleRate >> 8) & 0xFF);
    head[14] = static_cast<uint8_t>((sampleRate >> 16) & 0xFF);
    head[15] = static_cast<uint8_t>((sampleRate >> 24) & 0xFF);
    head[16] = 0;                                             // output gain
    head[17] = 0;
    head[18] = 0;                                             // channel mapping family
    return head;
}

}  // namespace

OpusCapability QueryCapability(bool isEncoder)
{
    OpusCapability cap;
    OH_AVCapability *handle = OH_AVCodec_GetCapability(OH_AVCODEC_MIMETYPE_AUDIO_OPUS, isEncoder);
    if (handle == nullptr) {
        OPUS_LOGE("no Opus %{public}s on this device", isEncoder ? "encoder" : "decoder");
        return cap;
    }
    cap.supported = true;
    cap.isHardware = OH_AVCapability_IsHardware(handle);
    const char *name = OH_AVCapability_GetName(handle);
    cap.name = (name == nullptr) ? "" : name;

    const int32_t *rates = nullptr;
    uint32_t rateCount = 0;
    if (OH_AVCapability_GetAudioSupportedSampleRates(handle, &rates, &rateCount) == AV_ERR_OK &&
        rates != nullptr) {
        cap.sampleRates.assign(rates, rates + rateCount);
    }
    OH_AVRange range = {0, 0};
    if (OH_AVCapability_GetAudioChannelCountRange(handle, &range) == AV_ERR_OK) {
        cap.channelMin = range.minVal;
        cap.channelMax = range.maxVal;
    }
    if (isEncoder) {
        if (OH_AVCapability_GetEncoderBitrateRange(handle, &range) == AV_ERR_OK) {
            cap.bitrateMin = range.minVal;
            cap.bitrateMax = range.maxVal;
        }
        if (OH_AVCapability_GetEncoderComplexityRange(handle, &range) == AV_ERR_OK) {
            cap.complexityMin = range.minVal;
            cap.complexityMax = range.maxVal;
        }
    }
    return cap;
}

std::shared_ptr<OpusSession> OpusSession::Create(const OpusConfig &config, std::string &message)
{
    std::shared_ptr<OpusSession> session(new OpusSession(config));

    session->codec_ = OH_AudioCodec_CreateByMime(OH_AVCODEC_MIMETYPE_AUDIO_OPUS, config.isEncoder);
    if (session->codec_ == nullptr) {
        message = "OH_AudioCodec_CreateByMime failed, audio/opus is not available";
        return nullptr;
    }
    session->codecName_ = QueryCapability(config.isEncoder).name;

    OH_AVCodecCallback callback = {&OpusSession::OnError, &OpusSession::OnStreamChanged,
                                   &OpusSession::OnNeedInputBuffer, &OpusSession::OnNewOutputBuffer};
    OH_AVErrCode ret = OH_AudioCodec_RegisterCallback(session->codec_, callback, session.get());
    if (ret != AV_ERR_OK) {
        message = "OH_AudioCodec_RegisterCallback failed, code " + std::to_string(ret);
        return nullptr;
    }

    // The decoder is configured with the synthesised OpusHead first; if the
    // device rejects that key, retry with the plain description.
    bool withHeader = !config.isEncoder;
    while (true) {
        OH_AVFormat *format = session->BuildFormat(withHeader);
        ret = OH_AudioCodec_Configure(session->codec_, format);
        OH_AVFormat_Destroy(format);
        if (ret == AV_ERR_OK) {
            session->configNote_ = withHeader ? "configured with OpusHead" : "configured without OpusHead";
            break;
        }
        OPUS_LOGE("OH_AudioCodec_Configure failed (header=%{public}d), code %{public}d", withHeader, ret);
        if (!withHeader) {
            message = "OH_AudioCodec_Configure failed, code " + std::to_string(ret);
            return nullptr;
        }
        withHeader = false;
        OH_AudioCodec_Reset(session->codec_);
    }

    ret = OH_AudioCodec_Prepare(session->codec_);
    if (ret != AV_ERR_OK) {
        message = "OH_AudioCodec_Prepare failed, code " + std::to_string(ret);
        return nullptr;
    }
    OPUS_LOGI("opus %{public}s ready: %{public}s, %{public}d Hz, %{public}d ch",
              config.isEncoder ? "encoder" : "decoder", session->codecName_.c_str(),
              config.sampleRate, config.channelCount);
    return session;
}

OpusSession::~OpusSession()
{
    Stop();
    SetOutputHandler(nullptr);
    if (codec_ != nullptr) {
        OH_AudioCodec_Destroy(codec_);
        codec_ = nullptr;
    }
}

OH_AVFormat *OpusSession::BuildFormat(bool withIdentificationHeader) const
{
    OH_AVFormat *format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_SAMPLE_RATE, config_.sampleRate);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_CHANNEL_COUNT, config_.channelCount);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE);
    OH_AVFormat_SetLongValue(format, OH_MD_KEY_BITRATE, config_.bitrate);
    if (config_.isEncoder) {
        // Opus complexity: a lower value means less CPU and less algorithmic
        // work, which is what a low-latency voice pipeline wants.
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUDIO_COMPRESSION_LEVEL, config_.complexity);
    } else if (withIdentificationHeader) {
        std::vector<uint8_t> head = BuildOpusHead(config_.channelCount, config_.sampleRate);
        OH_AVFormat_SetBuffer(format, OH_MD_KEY_IDENTIFICATION_HEADER, head.data(), head.size());
    }
    return format;
}

bool OpusSession::Start(std::string &message)
{
    OH_AVErrCode ret = OH_AudioCodec_Start(codec_);
    if (ret != AV_ERR_OK) {
        message = "OH_AudioCodec_Start failed, code " + std::to_string(ret);
        return false;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    running_ = true;
    return true;
}

void OpusSession::Stop()
{
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!running_) {
            return;
        }
        running_ = false;
    }
    if (codec_ != nullptr) {
        OH_AudioCodec_Stop(codec_);
    }
    std::lock_guard<std::mutex> lock(mutex_);
    freeInputs_.clear();
    pushTimeNs_.clear();
}

void OpusSession::Flush()
{
    if (codec_ == nullptr) {
        return;
    }
    OH_AudioCodec_Flush(codec_);
    std::lock_guard<std::mutex> lock(mutex_);
    freeInputs_.clear();   // every queued index is invalidated by Flush
    pushTimeNs_.clear();
}

void OpusSession::SetOutputHandler(OutputHandler handler)
{
    std::lock_guard<std::mutex> lock(handlerMutex_);
    handler_ = std::move(handler);
}

int32_t OpusSession::FrameBytes() const
{
    return config_.sampleRate * config_.channelCount * BYTES_PER_SAMPLE * config_.frameSizeMs / 1000;
}

bool OpusSession::Push(const uint8_t *data, size_t size, int64_t ptsUs, uint32_t flags)
{
    uint32_t index = 0;
    OH_AVBuffer *buffer = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!running_ || freeInputs_.empty()) {
            stats_.dropped++;
            return false;
        }
        index = freeInputs_.front().first;
        buffer = freeInputs_.front().second;
        freeInputs_.pop_front();
    }

    const int32_t capacity = OH_AVBuffer_GetCapacity(buffer);
    const int32_t copySize = std::min(static_cast<int32_t>(size), capacity);
    uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
    if (addr == nullptr || copySize <= 0) {
        OH_AudioCodec_PushInputBuffer(codec_, index);
        return false;
    }
    std::copy_n(data, static_cast<size_t>(copySize), addr);

    OH_AVCodecBufferAttr attr;
    attr.pts = ptsUs;
    attr.size = copySize;
    attr.offset = 0;
    attr.flags = flags;
    OH_AVBuffer_SetBufferAttr(buffer, &attr);

    {
        std::lock_guard<std::mutex> lock(mutex_);
        pushTimeNs_[ptsUs] = NowNs();
        stats_.inFrames++;
        stats_.inBytes += static_cast<uint64_t>(copySize);
    }
    OH_AVErrCode ret = OH_AudioCodec_PushInputBuffer(codec_, index);
    if (ret != AV_ERR_OK) {
        OPUS_LOGE("OH_AudioCodec_PushInputBuffer failed, code %{public}d", ret);
        return false;
    }
    return true;
}

OpusStats OpusSession::GetStats() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return stats_;
}

void OpusSession::Dispatch(std::unique_ptr<CodecOutput> output)
{
    std::lock_guard<std::mutex> lock(handlerMutex_);
    if (handler_) {
        handler_(std::move(output));
    }
}

void OpusSession::OnError(OH_AVCodec *codec, int32_t errorCode, void *userData)
{
    (void)codec;
    auto *self = static_cast<OpusSession *>(userData);
    if (self == nullptr) {
        return;
    }
    OPUS_LOGE("codec error %{public}d", errorCode);
    auto output = std::make_unique<CodecOutput>();
    output->errorCode = errorCode;
    self->Dispatch(std::move(output));
}

void OpusSession::OnStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData)
{
    (void)codec;
    (void)userData;
    if (format != nullptr) {
        OPUS_LOGI("stream changed: %{public}s", OH_AVFormat_DumpInfo(format));
    }
}

void OpusSession::OnNeedInputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData)
{
    (void)codec;
    auto *self = static_cast<OpusSession *>(userData);
    if (self == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(self->mutex_);
    self->freeInputs_.emplace_back(index, buffer);
}

void OpusSession::OnNewOutputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData)
{
    auto *self = static_cast<OpusSession *>(userData);
    if (self == nullptr) {
        return;
    }
    OH_AVCodecBufferAttr attr;
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) {
        OH_AudioCodec_FreeOutputBuffer(codec, index);
        return;
    }
    auto output = std::make_unique<CodecOutput>();
    output->pts = attr.pts;
    output->flags = attr.flags;
    const uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
    if (addr != nullptr && attr.size > 0) {
        output->data.assign(addr + attr.offset, addr + attr.offset + attr.size);
    }
    // Release the codec-owned buffer as early as possible: holding output
    // buffers back is the usual reason a real-time pipeline stalls.
    OH_AudioCodec_FreeOutputBuffer(codec, index);

    {
        std::lock_guard<std::mutex> lock(self->mutex_);
        auto it = self->pushTimeNs_.find(attr.pts);
        if (it != self->pushTimeNs_.end()) {
            output->latencyMs = static_cast<double>(NowNs() - it->second) / 1e6;
            self->pushTimeNs_.erase(it);
        }
        OpusStats &stats = self->stats_;
        stats.outFrames++;
        stats.outBytes += output->data.size();
        if (output->latencyMs > 0.0) {
            stats.lastLatencyMs = output->latencyMs;
            stats.maxLatencyMs = std::max(stats.maxLatencyMs, output->latencyMs);
            stats.avgLatencyMs += (output->latencyMs - stats.avgLatencyMs) /
                                  static_cast<double>(stats.outFrames);
        }
    }
    self->Dispatch(std::move(output));
}

}  // namespace opusdemo

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
 * NAPI surface of the Opus sample: exposes the AVCodec based OpusSession to
 * ArkTS as the module "libopuscodec.so".
 *
 * Output frames are produced on codec threads and forwarded to the ArkTS
 * callback through a napi_threadsafe_function, so the ArkTS pipeline never
 * polls and never blocks the UI thread.
 */
#include <algorithm>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

#include <hilog/log.h>
#include <napi/native_api.h>

#include "opus_session.h"

namespace {

using opusdemo::CodecOutput;
using opusdemo::OpusCapability;
using opusdemo::OpusConfig;
using opusdemo::OpusSession;
using opusdemo::OpusStats;

#define NAPI_LOGE(...) ((void)OH_LOG_Print(LOG_APP, LOG_ERROR, 0x3200, "OpusCodecNapi", __VA_ARGS__))

struct SessionEntry {
    std::shared_ptr<OpusSession> session;
    napi_threadsafe_function tsfn = nullptr;
};

std::mutex g_registryMutex;
std::unordered_map<int32_t, std::shared_ptr<SessionEntry>> g_sessions;
int32_t g_nextHandle = 1;

std::shared_ptr<SessionEntry> FindEntry(int32_t handle)
{
    std::lock_guard<std::mutex> lock(g_registryMutex);
    auto it = g_sessions.find(handle);
    return (it == g_sessions.end()) ? nullptr : it->second;
}

// ---------------------------------------------------------------- helpers ---

napi_value MakeInt(napi_env env, int64_t value)
{
    napi_value result = nullptr;
    napi_create_double(env, static_cast<double>(value), &result);
    return result;
}

napi_value MakeDouble(napi_env env, double value)
{
    napi_value result = nullptr;
    napi_create_double(env, value, &result);
    return result;
}

napi_value MakeBool(napi_env env, bool value)
{
    napi_value result = nullptr;
    napi_get_boolean(env, value, &result);
    return result;
}

napi_value MakeString(napi_env env, const std::string &value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &result);
    return result;
}

int32_t ReadIntProperty(napi_env env, napi_value object, const char *key, int32_t fallback)
{
    napi_value value = nullptr;
    if (napi_get_named_property(env, object, key, &value) != napi_ok || value == nullptr) {
        return fallback;
    }
    napi_valuetype type = napi_undefined;
    napi_typeof(env, value, &type);
    if (type != napi_number) {
        return fallback;
    }
    double number = 0;
    napi_get_value_double(env, value, &number);
    return static_cast<int32_t>(number);
}

bool ReadBoolProperty(napi_env env, napi_value object, const char *key, bool fallback)
{
    napi_value value = nullptr;
    if (napi_get_named_property(env, object, key, &value) != napi_ok || value == nullptr) {
        return fallback;
    }
    napi_valuetype type = napi_undefined;
    napi_typeof(env, value, &type);
    if (type != napi_boolean) {
        return fallback;
    }
    bool result = fallback;
    napi_get_value_bool(env, value, &result);
    return result;
}

int32_t ReadHandleArg(napi_env env, napi_value value)
{
    double number = -1;
    napi_get_value_double(env, value, &number);
    return static_cast<int32_t>(number);
}

// --------------------------------------------------------- codec callback ---

/** Runs on the ArkTS thread: turns a CodecOutput into the JS frame object. */
void CallJsOutput(napi_env env, napi_value callback, void *context, void *data)
{
    (void)context;
    std::unique_ptr<CodecOutput> output(static_cast<CodecOutput *>(data));
    if (env == nullptr || callback == nullptr || output == nullptr) {
        return;
    }
    napi_value frame = nullptr;
    napi_create_object(env, &frame);

    napi_value arrayBuffer = nullptr;
    void *raw = nullptr;
    napi_create_arraybuffer(env, output->data.size(), &raw, &arrayBuffer);
    if (raw != nullptr && !output->data.empty()) {
        std::copy(output->data.begin(), output->data.end(), static_cast<uint8_t *>(raw));
    }
    napi_set_named_property(env, frame, "data", arrayBuffer);
    napi_set_named_property(env, frame, "pts", MakeInt(env, output->pts));
    napi_set_named_property(env, frame, "flags", MakeInt(env, output->flags));
    napi_set_named_property(env, frame, "latencyMs", MakeDouble(env, output->latencyMs));
    napi_set_named_property(env, frame, "errorCode", MakeInt(env, output->errorCode));

    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_value ignored = nullptr;
    napi_call_function(env, undefined, callback, 1, &frame, &ignored);
}

// --------------------------------------------------------------- exports ---

napi_value GetCapability(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool isEncoder = true;
    if (argc >= 1) {
        napi_get_value_bool(env, args[0], &isEncoder);
    }

    OpusCapability cap = opusdemo::QueryCapability(isEncoder);
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_set_named_property(env, result, "supported", MakeBool(env, cap.supported));
    napi_set_named_property(env, result, "isEncoder", MakeBool(env, isEncoder));
    napi_set_named_property(env, result, "isHardware", MakeBool(env, cap.isHardware));
    napi_set_named_property(env, result, "name", MakeString(env, cap.name));
    napi_set_named_property(env, result, "channelMin", MakeInt(env, cap.channelMin));
    napi_set_named_property(env, result, "channelMax", MakeInt(env, cap.channelMax));
    napi_set_named_property(env, result, "bitrateMin", MakeInt(env, cap.bitrateMin));
    napi_set_named_property(env, result, "bitrateMax", MakeInt(env, cap.bitrateMax));
    napi_set_named_property(env, result, "complexityMin", MakeInt(env, cap.complexityMin));
    napi_set_named_property(env, result, "complexityMax", MakeInt(env, cap.complexityMax));

    napi_value rates = nullptr;
    napi_create_array_with_length(env, cap.sampleRates.size(), &rates);
    for (size_t i = 0; i < cap.sampleRates.size(); ++i) {
        napi_set_element(env, rates, i, MakeInt(env, cap.sampleRates[i]));
    }
    napi_set_named_property(env, result, "sampleRates", rates);
    return result;
}

napi_value CreateSession(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "createSession expects a configuration object");
        return nullptr;
    }

    OpusConfig config;
    config.isEncoder = ReadBoolProperty(env, args[0], "isEncoder", true);
    config.sampleRate = ReadIntProperty(env, args[0], "sampleRate", config.sampleRate);
    config.channelCount = ReadIntProperty(env, args[0], "channelCount", config.channelCount);
    config.bitrate = ReadIntProperty(env, args[0], "bitrate", config.bitrate);
    config.complexity = ReadIntProperty(env, args[0], "complexity", config.complexity);
    config.frameSizeMs = ReadIntProperty(env, args[0], "frameSizeMs", config.frameSizeMs);

    std::string message;
    std::shared_ptr<OpusSession> session = OpusSession::Create(config, message);
    if (session == nullptr) {
        NAPI_LOGE("createSession failed: %{public}s", message.c_str());
        napi_throw_error(env, nullptr, message.c_str());
        return nullptr;
    }

    auto entry = std::make_shared<SessionEntry>();
    entry->session = session;
    int32_t handle = 0;
    {
        std::lock_guard<std::mutex> lock(g_registryMutex);
        handle = g_nextHandle++;
        g_sessions[handle] = entry;
    }
    return MakeInt(env, handle);
}

napi_value SetOutputCallback(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_error(env, nullptr, "setOutputCallback expects (handle, callback)");
        return nullptr;
    }
    std::shared_ptr<SessionEntry> entry = FindEntry(ReadHandleArg(env, args[0]));
    if (entry == nullptr) {
        napi_throw_error(env, nullptr, "unknown codec handle");
        return nullptr;
    }

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "OpusCodecOutput", NAPI_AUTO_LENGTH, &resourceName);
    napi_threadsafe_function tsfn = nullptr;
    napi_status status = napi_create_threadsafe_function(env, args[1], nullptr, resourceName,
                                                         0, 1, nullptr, nullptr, nullptr,
                                                         CallJsOutput, &tsfn);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "napi_create_threadsafe_function failed");
        return nullptr;
    }
    // Do not let the codec callback keep the ArkTS event loop alive.
    napi_unref_threadsafe_function(env, tsfn);
    entry->tsfn = tsfn;

    entry->session->SetOutputHandler([tsfn](std::unique_ptr<CodecOutput> output) {
        CodecOutput *raw = output.release();
        if (napi_call_threadsafe_function(tsfn, raw, napi_tsfn_nonblocking) != napi_ok) {
            delete raw;   // queue full or function closing: drop the frame
        }
    });
    return nullptr;
}

napi_value Start(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::shared_ptr<SessionEntry> entry = FindEntry(ReadHandleArg(env, args[0]));
    if (entry == nullptr) {
        napi_throw_error(env, nullptr, "unknown codec handle");
        return nullptr;
    }
    std::string message;
    if (!entry->session->Start(message)) {
        napi_throw_error(env, nullptr, message.c_str());
    }
    return nullptr;
}

napi_value Push(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        napi_throw_error(env, nullptr, "push expects (handle, data, ptsUs[, flags])");
        return nullptr;
    }
    std::shared_ptr<SessionEntry> entry = FindEntry(ReadHandleArg(env, args[0]));
    if (entry == nullptr) {
        napi_throw_error(env, nullptr, "unknown codec handle");
        return nullptr;
    }

    void *data = nullptr;
    size_t length = 0;
    if (napi_get_arraybuffer_info(env, args[1], &data, &length) != napi_ok || data == nullptr) {
        napi_throw_error(env, nullptr, "push expects an ArrayBuffer as second argument");
        return nullptr;
    }
    double pts = 0;
    napi_get_value_double(env, args[2], &pts);
    uint32_t flags = 0;
    if (argc >= 4) {
        double rawFlags = 0;
        napi_get_value_double(env, args[3], &rawFlags);
        flags = static_cast<uint32_t>(rawFlags);
    }

    bool accepted = entry->session->Push(static_cast<uint8_t *>(data), length,
                                         static_cast<int64_t>(pts), flags);
    return MakeBool(env, accepted);
}

napi_value Flush(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::shared_ptr<SessionEntry> entry = FindEntry(ReadHandleArg(env, args[0]));
    if (entry != nullptr) {
        entry->session->Flush();
    }
    return nullptr;
}

napi_value Stop(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::shared_ptr<SessionEntry> entry = FindEntry(ReadHandleArg(env, args[0]));
    if (entry != nullptr) {
        entry->session->Stop();
    }
    return nullptr;
}

napi_value Destroy(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t handle = ReadHandleArg(env, args[0]);

    std::shared_ptr<SessionEntry> entry;
    {
        std::lock_guard<std::mutex> lock(g_registryMutex);
        auto it = g_sessions.find(handle);
        if (it == g_sessions.end()) {
            return nullptr;
        }
        entry = it->second;
        g_sessions.erase(it);
    }
    // Stop first so no codec thread can post another frame, then drop the
    // handler and release the threadsafe function.
    entry->session->Stop();
    entry->session->SetOutputHandler(nullptr);
    if (entry->tsfn != nullptr) {
        napi_release_threadsafe_function(entry->tsfn, napi_tsfn_release);
        entry->tsfn = nullptr;
    }
    entry->session.reset();
    return nullptr;
}

napi_value GetStats(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::shared_ptr<SessionEntry> entry = FindEntry(ReadHandleArg(env, args[0]));
    napi_value result = nullptr;
    napi_create_object(env, &result);
    if (entry == nullptr) {
        return result;
    }
    OpusStats stats = entry->session->GetStats();
    napi_set_named_property(env, result, "inFrames", MakeInt(env, stats.inFrames));
    napi_set_named_property(env, result, "outFrames", MakeInt(env, stats.outFrames));
    napi_set_named_property(env, result, "inBytes", MakeInt(env, stats.inBytes));
    napi_set_named_property(env, result, "outBytes", MakeInt(env, stats.outBytes));
    napi_set_named_property(env, result, "dropped", MakeInt(env, stats.dropped));
    napi_set_named_property(env, result, "lastLatencyMs", MakeDouble(env, stats.lastLatencyMs));
    napi_set_named_property(env, result, "avgLatencyMs", MakeDouble(env, stats.avgLatencyMs));
    napi_set_named_property(env, result, "maxLatencyMs", MakeDouble(env, stats.maxLatencyMs));
    return result;
}

napi_value GetSessionInfo(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::shared_ptr<SessionEntry> entry = FindEntry(ReadHandleArg(env, args[0]));
    napi_value result = nullptr;
    napi_create_object(env, &result);
    if (entry == nullptr) {
        return result;
    }
    const OpusConfig &config = entry->session->Config();
    napi_set_named_property(env, result, "codecName", MakeString(env, entry->session->CodecName()));
    napi_set_named_property(env, result, "configNote", MakeString(env, entry->session->ConfigNote()));
    napi_set_named_property(env, result, "isEncoder", MakeBool(env, config.isEncoder));
    napi_set_named_property(env, result, "sampleRate", MakeInt(env, config.sampleRate));
    napi_set_named_property(env, result, "channelCount", MakeInt(env, config.channelCount));
    napi_set_named_property(env, result, "bitrate", MakeInt(env, config.bitrate));
    napi_set_named_property(env, result, "complexity", MakeInt(env, config.complexity));
    napi_set_named_property(env, result, "frameSizeMs", MakeInt(env, config.frameSizeMs));
    napi_set_named_property(env, result, "frameBytes", MakeInt(env, entry->session->FrameBytes()));
    return result;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"getCapability", nullptr, GetCapability, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"createSession", nullptr, CreateSession, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setOutputCallback", nullptr, SetOutputCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"push", nullptr, Push, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"flush", nullptr, Flush, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"destroy", nullptr, Destroy, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStats", nullptr, GetStats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSessionInfo", nullptr, GetSessionInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

napi_module g_opusModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "opuscodec",
    .nm_priv = nullptr,
    .reserved = {0},
};

}  // namespace

extern "C" __attribute__((constructor)) void RegisterOpusCodecModule(void)
{
    napi_module_register(&g_opusModule);
}

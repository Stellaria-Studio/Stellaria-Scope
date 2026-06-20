#include "StellarScopeNative.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <sys/sysctl.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

extern "C" {
typedef const void *IOReportSubscriptionRef;
CFDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(const void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
int32_t IOReportStateGetCount(CFDictionaryRef);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
}

namespace {

enum SMCCommand : uint8_t {
    kSMCKernelIndex = 2,
    kSMCReadBytes = 5,
    kSMCReadIndex = 8,
    kSMCReadKeyInfo = 9,
};

struct SMCVersion {
    uint8_t major = 0;
    uint8_t minor = 0;
    uint8_t build = 0;
    uint8_t reserved = 0;
    uint16_t release = 0;
};

struct SMCPLimitData {
    uint16_t version = 0;
    uint16_t length = 0;
    uint32_t cpuPLimit = 0;
    uint32_t gpuPLimit = 0;
    uint32_t memPLimit = 0;
};

struct SMCKeyInfo {
    uint32_t dataSize = 0;
    uint32_t dataType = 0;
    uint8_t dataAttributes = 0;
};

struct SMCParamStruct {
    uint32_t key = 0;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result = 0;
    uint8_t status = 0;
    uint8_t data8 = 0;
    uint32_t data32 = 0;
    uint8_t bytes[32] = {};
};

struct DecodedSMC {
    bool ok = false;
    double value = 0;
    std::string text;
    std::string type;
};

void copyString(char *dst, size_t size, const std::string &src) {
    if (size == 0) { return; }
    std::snprintf(dst, size, "%s", src.c_str());
}

void addMetric(std::vector<SSNativeMetric> &out,
               const std::string &id,
               const std::string &title,
               const std::string &category,
               double value,
               const std::string &unit,
               const std::string &source,
               const std::string &rawKey,
               bool experimental = true) {
    SSNativeMetric metric{};
    copyString(metric.id, sizeof(metric.id), id);
    copyString(metric.title, sizeof(metric.title), title);
    copyString(metric.category, sizeof(metric.category), category);
    copyString(metric.unit, sizeof(metric.unit), unit);
    copyString(metric.source, sizeof(metric.source), source);
    copyString(metric.rawKey, sizeof(metric.rawKey), rawKey);
    metric.value = value;
    metric.hasValue = 1;
    metric.isExperimental = experimental ? 1 : 0;
    out.push_back(metric);
}

void addTextMetric(std::vector<SSNativeMetric> &out,
                   const std::string &id,
                   const std::string &title,
                   const std::string &category,
                   const std::string &text,
                   const std::string &source,
                   const std::string &rawKey,
                   bool experimental = true) {
    SSNativeMetric metric{};
    copyString(metric.id, sizeof(metric.id), id);
    copyString(metric.title, sizeof(metric.title), title);
    copyString(metric.category, sizeof(metric.category), category);
    copyString(metric.source, sizeof(metric.source), source);
    copyString(metric.rawKey, sizeof(metric.rawKey), rawKey);
    copyString(metric.text, sizeof(metric.text), text);
    metric.hasValue = 0;
    metric.isExperimental = experimental ? 1 : 0;
    out.push_back(metric);
}

uint32_t fourCC(const char *key) {
    return (uint32_t(uint8_t(key[0])) << 24)
        | (uint32_t(uint8_t(key[1])) << 16)
        | (uint32_t(uint8_t(key[2])) << 8)
        | uint32_t(uint8_t(key[3]));
}

std::string typeString(uint32_t value) {
    char chars[5] = {
        char((value >> 24) & 0xff),
        char((value >> 16) & 0xff),
        char((value >> 8) & 0xff),
        char(value & 0xff),
        0
    };
    return std::string(chars);
}

std::string trimSpaces(std::string value) {
    value.erase(std::remove_if(value.begin(), value.end(), ::isspace), value.end());
    return value;
}

bool smcCall(io_connect_t conn, const SMCParamStruct &input, SMCParamStruct &output) {
    size_t outSize = sizeof(SMCParamStruct);
    kern_return_t result = IOConnectCallStructMethod(
        conn,
        kSMCKernelIndex,
        &input,
        sizeof(SMCParamStruct),
        &output,
        &outSize
    );
    return result == KERN_SUCCESS;
}

std::string smcKeyName(uint32_t key) {
    char chars[5] = {
        char((key >> 24) & 0xff),
        char((key >> 16) & 0xff),
        char((key >> 8) & 0xff),
        char(key & 0xff),
        0
    };
    return std::string(chars);
}

std::string cfString(CFStringRef value) {
    if (!value) { return ""; }
    char buffer[256] = {};
    if (CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        return std::string(buffer);
    }
    CFIndex length = CFStringGetLength(value);
    CFIndex maxSize = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    std::vector<char> dynamic(size_t(std::max<CFIndex>(maxSize, 1)));
    if (CFStringGetCString(value, dynamic.data(), dynamic.size(), kCFStringEncodingUTF8)) {
        return std::string(dynamic.data());
    }
    return "";
}

CFTypeRef dictValue(CFDictionaryRef dict, const char *key) {
    if (!dict) { return nullptr; }
    CFStringRef cfKey = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    if (!cfKey) { return nullptr; }
    CFTypeRef value = CFDictionaryGetValue(dict, cfKey);
    CFRelease(cfKey);
    return value;
}

bool startsWith(const std::string &value, const std::string &prefix) {
    return value.size() >= prefix.size() && value.compare(0, prefix.size(), prefix) == 0;
}

bool endsWith(const std::string &value, const std::string &suffix) {
    return value.size() >= suffix.size() && value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::string normalizedIDComponent(const std::string &value) {
    std::string out;
    out.reserve(value.size());
    for (char ch : value) {
        if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) {
            out.push_back(ch);
        } else if (ch >= 'A' && ch <= 'Z') {
            out.push_back(char(ch - 'A' + 'a'));
        } else if (!out.empty() && out.back() != '_') {
            out.push_back('_');
        }
    }
    while (!out.empty() && out.back() == '_') { out.pop_back(); }
    return out.empty() ? "metric" : out;
}

std::string normalizedSMCKeyComponent(const std::string &key) {
    std::string out;
    out.reserve(key.size() * 2);
    for (char ch : key) {
        if (ch >= 'A' && ch <= 'Z') {
            out.push_back(char(ch - 'A' + 'a'));
        } else if (ch >= 'a' && ch <= 'z') {
            out.push_back('_');
            out.push_back(ch);
        } else if (ch >= '0' && ch <= '9') {
            out.push_back(ch);
        } else {
            out.push_back('_');
        }
    }
    return out.empty() ? "key" : out;
}

std::vector<uint32_t> parseDVFSFrequenciesHz(CFDictionaryRef properties, const char *key) {
    std::vector<uint32_t> freqs;
    CFTypeRef value = dictValue(properties, key);
    if (!value || CFGetTypeID(value) != CFDataGetTypeID()) { return freqs; }
    CFDataRef data = static_cast<CFDataRef>(value);
    CFIndex length = CFDataGetLength(data);
    if (length < 8) { return freqs; }
    std::vector<uint8_t> bytes(static_cast<size_t>(length));
    CFDataGetBytes(data, CFRangeMake(0, length), bytes.data());
    for (size_t offset = 0; offset + 7 < bytes.size(); offset += 8) {
        uint32_t raw = uint32_t(bytes[offset])
            | (uint32_t(bytes[offset + 1]) << 8)
            | (uint32_t(bytes[offset + 2]) << 16)
            | (uint32_t(bytes[offset + 3]) << 24);
        if (raw == 0) { continue; }
        uint64_t hz = raw < 10'000'000 ? uint64_t(raw) * 1000ULL : uint64_t(raw);
        freqs.push_back(uint32_t(std::min<uint64_t>(hz, UINT32_MAX)));
    }
    return freqs;
}

std::vector<std::pair<std::string, int64_t>> stateResidencies(CFDictionaryRef item) {
    std::vector<std::pair<std::string, int64_t>> values;
    int32_t count = IOReportStateGetCount(item);
    for (int32_t index = 0; index < count; ++index) {
        std::string name = cfString(IOReportStateGetNameForIndex(item, index));
        if (name.empty()) { name = "S" + std::to_string(index); }
        values.emplace_back(name, IOReportStateGetResidency(item, index));
    }
    return values;
}

struct FrequencyEstimate {
    double frequencyHz = 0;
    double activePercent = 0;
};

FrequencyEstimate estimateFrequency(CFDictionaryRef item, const std::vector<uint32_t> &freqs) {
    FrequencyEstimate estimate;
    if (freqs.empty()) { return estimate; }
    auto states = stateResidencies(item);
    if (states.size() <= freqs.size()) { return estimate; }
    size_t offset = 0;
    while (offset < states.size()
           && (states[offset].first == "IDLE" || states[offset].first == "DOWN" || states[offset].first == "OFF")) {
        ++offset;
    }
    if (offset >= states.size()) { return estimate; }

    double active = 0;
    double total = 0;
    for (const auto &state : states) { total += std::max<int64_t>(0, state.second); }
    for (size_t index = offset; index < states.size(); ++index) { active += std::max<int64_t>(0, states[index].second); }
    if (active <= 0 || total <= 0) { return estimate; }

    double weighted = 0;
    size_t usable = std::min(freqs.size(), states.size() - offset);
    for (size_t index = 0; index < usable; ++index) {
        double residency = std::max<int64_t>(0, states[offset + index].second);
        weighted += (residency / active) * double(freqs[index]);
    }
    estimate.frequencyHz = weighted;
    estimate.activePercent = (active / total) * 100.0;
    return estimate;
}

double energyDeltaToMilliwatts(CFDictionaryRef item, const std::string &unit, double elapsedMS) {
    if (elapsedMS <= 0) { return 0; }
    double value = double(IOReportSimpleGetIntegerValue(item, 0));
    double watts = 0;
    if (unit == "mJ") {
        watts = (value / 1000.0) / (elapsedMS / 1000.0);
    } else if (unit == "uJ") {
        watts = (value / 1'000'000.0) / (elapsedMS / 1000.0);
    } else if (unit == "nJ") {
        watts = (value / 1'000'000'000.0) / (elapsedMS / 1000.0);
    }
    return watts * 1000.0;
}

bool smcRead(io_connect_t conn, const char *key, DecodedSMC &decoded) {
    if (std::strlen(key) != 4) { return false; }
    SMCParamStruct infoIn{};
    infoIn.key = fourCC(key);
    infoIn.data8 = kSMCReadKeyInfo;
    SMCParamStruct infoOut{};
    if (!smcCall(conn, infoIn, infoOut) || infoOut.result != 0) { return false; }

    SMCParamStruct readIn{};
    readIn.key = infoIn.key;
    readIn.keyInfo.dataSize = infoOut.keyInfo.dataSize;
    readIn.data8 = kSMCReadBytes;
    SMCParamStruct readOut{};
    if (!smcCall(conn, readIn, readOut) || readOut.result != 0) { return false; }

    decoded.ok = true;
    decoded.type = typeString(infoOut.keyInfo.dataType);
    const uint32_t size = std::min<uint32_t>(infoOut.keyInfo.dataSize, 32);
    const uint8_t *raw = readOut.bytes;

    const std::string compactType = trimSpaces(decoded.type);
    if (key[0] == 'F' && size >= 4) {
        float value = 0;
        std::memcpy(&value, raw, sizeof(float));
        decoded.value = double(value);
        return std::isfinite(decoded.value);
    }
    if (compactType == "ui8" && size >= 1) {
        decoded.value = raw[0];
        return true;
    }
    if (compactType == "ui16" && size >= 2) {
        decoded.value = double((uint16_t(raw[0]) << 8) | uint16_t(raw[1]));
        return true;
    }
    if (compactType == "ui32" && size >= 4) {
        decoded.value = double((uint32_t(raw[0]) << 24) | (uint32_t(raw[1]) << 16) | (uint32_t(raw[2]) << 8) | uint32_t(raw[3]));
        return true;
    }
    if (compactType == "fpe2" && size >= 2) {
        uint16_t fixed = (uint16_t(raw[0]) << 8) | uint16_t(raw[1]);
        decoded.value = double(fixed) / 4.0;
        return true;
    }
    if (compactType == "flt" && size >= 4) {
        float value = 0;
        std::memcpy(&value, raw, sizeof(float));
        decoded.value = double(value);
        return std::isfinite(decoded.value);
    }
    if (key[0] == 'F' && size >= 2) {
        uint16_t fixed = (uint16_t(raw[0]) << 8) | uint16_t(raw[1]);
        decoded.value = double(fixed) / 4.0;
        return true;
    }
    std::string printable;
    for (uint32_t i = 0; i < size; ++i) {
        if (raw[i] >= 0x20 && raw[i] < 0x7f) {
            printable.push_back(char(raw[i]));
        }
    }
    if (!printable.empty()) {
        decoded.text = printable;
        return true;
    }
    return false;
}

bool smcReadKeyByIndex(io_connect_t conn, uint32_t index, std::string &keyName) {
    SMCParamStruct input{};
    input.data8 = kSMCReadIndex;
    input.data32 = index;
    SMCParamStruct output{};
    if (!smcCall(conn, input, output) || output.result != 0) { return false; }
    keyName = smcKeyName(output.key);
    return keyName.size() == 4;
}

uint32_t smcKeyCount(io_connect_t conn) {
    DecodedSMC decoded;
    if (!smcRead(conn, "#KEY", decoded) || !decoded.ok || decoded.value <= 0) { return 0; }
    return uint32_t(std::min(20000.0, decoded.value));
}

bool plausibleTemperature(double value) {
    return std::isfinite(value) && value >= 5 && value < 140;
}

std::string smcTemperatureTitle(const std::string &key) {
    if (key == "TC0P") { return "CPU Proximity Temperature"; }
    if (key == "TC0E") { return "CPU E-cluster Temperature"; }
    if (key == "TC0F") { return "CPU P-cluster Temperature"; }
    if (key == "TC0D") { return "CPU Die Temperature"; }
    if (key == "TG0P") { return "GPU Proximity Temperature"; }
    if (key == "TG0D") { return "GPU Die Temperature"; }
    if (key == "Tp0P") { return "SoC Proximity Temperature"; }
    if (key == "Ts0P") { return "Palm Rest Temperature"; }
    if (startsWith(key, "TC")) { return "CPU Temperature " + key; }
    if (startsWith(key, "TG")) { return "GPU Temperature " + key; }
    if (startsWith(key, "Tp") || startsWith(key, "TP")) { return "SoC Temperature " + key; }
    if (startsWith(key, "Ts") || startsWith(key, "TS")) { return "System Temperature " + key; }
    if (startsWith(key, "TB")) { return "Battery Temperature " + key; }
    if (startsWith(key, "Tm") || startsWith(key, "TM")) { return "Memory Temperature " + key; }
    return "SMC Temperature " + key;
}

std::string smcTemperatureAliasID(const std::string &key) {
    if (key == "TC0P") { return "native.smc.cpu_proximity_temperature_c"; }
    if (key == "TC0E") { return "native.smc.cpu_efficiency_temperature_c"; }
    if (key == "TC0F") { return "native.smc.cpu_performance_temperature_c"; }
    if (key == "TC0D") { return "native.smc.cpu_die_temperature_c"; }
    if (key == "TG0P") { return "native.smc.gpu_proximity_temperature_c"; }
    if (key == "TG0D") { return "native.smc.gpu_die_temperature_c"; }
    if (key == "Tp0P") { return "native.smc.soc_proximity_temperature_c"; }
    if (key == "Ts0P") { return "native.smc.palm_rest_temperature_c"; }
    return "";
}

void emitSMCTemperature(std::vector<SSNativeMetric> &out, std::set<std::string> &seenKeys, const std::string &key, double value) {
    if (!plausibleTemperature(value)) { return; }
    seenKeys.insert(key);
    const std::string title = smcTemperatureTitle(key);
    const std::string generalID = "native.smc.temperature." + normalizedSMCKeyComponent(key) + "_c";
    addMetric(out, generalID, title, "Temperature", value, "C", "NativeSMC", key, true);
    const std::string aliasID = smcTemperatureAliasID(key);
    if (!aliasID.empty()) {
        addMetric(out, aliasID, title, "Temperature", value, "C", "NativeSMC", key, true);
    }
}

void collectSMC(std::vector<SSNativeMetric> &out) {
    io_service_t service = IO_OBJECT_NULL;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) == KERN_SUCCESS && iterator != IO_OBJECT_NULL) {
        io_object_t candidate = IO_OBJECT_NULL;
        while ((candidate = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
            io_name_t name = {};
            IORegistryEntryGetName(candidate, name);
            if (std::string(name) == "AppleSMCKeysEndpoint") {
                if (service != IO_OBJECT_NULL) {
                    IOObjectRelease(service);
                }
                service = candidate;
                break;
            }
            if (service == IO_OBJECT_NULL) {
                service = candidate;
            } else {
                IOObjectRelease(candidate);
            }
        }
        IOObjectRelease(iterator);
    }
    if (service == IO_OBJECT_NULL) {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    }
    if (service == IO_OBJECT_NULL) {
        addTextMetric(out, "native.smc.status", "Native SMC Status", "Raw", "AppleSMC unavailable", "NativeSMC", "AppleSMC", true);
        return;
    }
    io_connect_t conn = IO_OBJECT_NULL;
    kern_return_t openResult = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    if (openResult != KERN_SUCCESS) {
        addTextMetric(out, "native.smc.status", "Native SMC Status", "Raw", "AppleSMC open denied", "NativeSMC", "AppleSMC", true);
        return;
    }

    std::set<std::string> emittedTemperatureKeys;
    auto readTemp = [&](const char *key, const std::string &id, const std::string &title) {
        DecodedSMC value;
        if (smcRead(conn, key, value) && value.ok && plausibleTemperature(value.value)) {
            emittedTemperatureKeys.insert(key);
            addMetric(out, id, title, "Temperature", value.value, "C", "NativeSMC", key, true);
            addMetric(out, "native.smc.temperature." + normalizedSMCKeyComponent(key) + "_c", title, "Temperature", value.value, "C", "NativeSMC", key, true);
        }
    };

    readTemp("TC0P", "native.smc.cpu_proximity_temperature_c", "CPU Proximity Temperature");
    readTemp("TC0E", "native.smc.cpu_efficiency_temperature_c", "CPU E-cluster Temperature");
    readTemp("TC0F", "native.smc.cpu_performance_temperature_c", "CPU P-cluster Temperature");
    readTemp("TC0D", "native.smc.cpu_die_temperature_c", "CPU Die Temperature");
    readTemp("TG0P", "native.smc.gpu_proximity_temperature_c", "GPU Proximity Temperature");
    readTemp("TG0D", "native.smc.gpu_die_temperature_c", "GPU Die Temperature");
    readTemp("Tp0P", "native.smc.soc_proximity_temperature_c", "SoC Proximity Temperature");
    readTemp("Ts0P", "native.smc.palm_rest_temperature_c", "Palm Rest Temperature");

    uint32_t keyCount = smcKeyCount(conn);
    int emittedTemps = 0;
    if (keyCount > 0) {
        for (uint32_t index = 0; index < keyCount; ++index) {
            std::string key;
            if (!smcReadKeyByIndex(conn, index, key) || key.empty()) { continue; }
            if (emittedTemperatureKeys.find(key) != emittedTemperatureKeys.end()) { continue; }
            if (key[0] != 'T') { continue; }
            DecodedSMC temp;
            if (smcRead(conn, key.c_str(), temp) && temp.ok && plausibleTemperature(temp.value)) {
                emitSMCTemperature(out, emittedTemperatureKeys, key, temp.value);
                emittedTemps += 1;
            }
        }
        addMetric(out, "native.smc.temperature_key_count", "SMC Temperature Keys", "Temperature", int(emittedTemperatureKeys.size()), "", "NativeSMC", "#KEY/T*", true);
    }

    DecodedSMC fanCountValue;
    int fanCount = 2;
    if (smcRead(conn, "FNum", fanCountValue) && fanCountValue.ok) {
        fanCount = int(std::max(0.0, std::min(8.0, fanCountValue.value)));
        addMetric(out, "smc.fan_count", "SMC Fan Count", "Fan", fanCountValue.value, "", "NativeSMC", "FNum", true);
    }
    if (fanCount == 0) {
        fanCount = 2;
    }
    for (int index = 0; index < fanCount; ++index) {
        char key[5] = {};
        std::snprintf(key, sizeof(key), "F%dAc", index);
        DecodedSMC rpm;
        if (smcRead(conn, key, rpm) && rpm.ok && rpm.value >= 0 && rpm.value < 20000) {
            addMetric(out, "smc.fan" + std::to_string(index) + ".rpm", "Fan " + std::to_string(index) + " RPM", "Fan", rpm.value, "rpm", "NativeSMC", key, true);
            if (index == 0) {
                addMetric(out, "native.smc.fan_rpm", "Fan RPM", "Fan", rpm.value, "rpm", "NativeSMC", key, true);
            }
        }
        std::snprintf(key, sizeof(key), "F%dMn", index);
        DecodedSMC minRPM;
        if (smcRead(conn, key, minRPM) && minRPM.ok) {
            addMetric(out, "smc.fan" + std::to_string(index) + ".min_rpm", "Fan " + std::to_string(index) + " Min", "Fan", minRPM.value, "rpm", "NativeSMC", key, true);
        }
        std::snprintf(key, sizeof(key), "F%dMx", index);
        DecodedSMC maxRPM;
        if (smcRead(conn, key, maxRPM) && maxRPM.ok) {
            addMetric(out, "smc.fan" + std::to_string(index) + ".max_rpm", "Fan " + std::to_string(index) + " Max", "Fan", maxRPM.value, "rpm", "NativeSMC", key, true);
        }
    }

    IOServiceClose(conn);
}

void collectSysctl(std::vector<SSNativeMetric> &out) {
    auto readUInt64 = [&](const char *name, const std::string &id, const std::string &title) {
        uint64_t value = 0;
        size_t size = sizeof(value);
        if (sysctlbyname(name, &value, &size, nullptr, 0) == 0 && value > 0) {
            addMetric(out, id, title, "Frequency", double(value), "Hz", "NativeSysctl", name, true);
        }
    };
    readUInt64("hw.cpufrequency", "native.sysctl.cpu_frequency_hz", "CPU Frequency");
    readUInt64("hw.cpufrequency_max", "native.sysctl.cpu_frequency_max_hz", "CPU Max Frequency");
    readUInt64("hw.cpufrequency_min", "native.sysctl.cpu_frequency_min_hz", "CPU Min Frequency");
    readUInt64("hw.tbfrequency", "native.sysctl.timebase_frequency_hz", "Timebase Frequency");
}

struct PMGRFrequencies {
    std::vector<uint32_t> eCPU;
    std::vector<uint32_t> pCPU;
    std::vector<uint32_t> gpu;
};

PMGRFrequencies loadPMGRFrequencies(std::vector<SSNativeMetric> *out) {
    static PMGRFrequencies cached;
    static bool loaded = false;
    if (loaded) { return cached; }
    loaded = true;

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator);
    if (result != KERN_SUCCESS || iterator == IO_OBJECT_NULL) { return cached; }
    io_object_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        io_name_t name = {};
        IORegistryEntryGetName(service, name);
        if (std::string(name) == "pmgr") {
            CFMutableDictionaryRef props = nullptr;
            if (IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
                cached.eCPU = parseDVFSFrequenciesHz(props, "voltage-states1-sram");
                cached.pCPU = parseDVFSFrequenciesHz(props, "voltage-states5-sram");
                cached.gpu = parseDVFSFrequenciesHz(props, "voltage-states9");
                CFRelease(props);
                IOObjectRelease(service);
                break;
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);

    auto emitRange = [&](const std::vector<uint32_t> &values, const std::string &prefix, const std::string &title) {
        if (!out || values.empty()) { return; }
        auto minmax = std::minmax_element(values.begin(), values.end());
        addMetric(*out, prefix + ".min_frequency_hz", title + " Min Frequency", "Frequency", double(*minmax.first), "Hz", "NativePMGR", "pmgr.dvfs", true);
        addMetric(*out, prefix + ".max_frequency_hz", title + " Max Frequency", "Frequency", double(*minmax.second), "Hz", "NativePMGR", "pmgr.dvfs", true);
        addMetric(*out, prefix + ".states", title + " DVFS States", "Frequency", double(values.size()), "", "NativePMGR", "pmgr.dvfs", true);
    };
    emitRange(cached.eCPU, "native.pmgr.e_cluster", "E Cluster");
    emitRange(cached.pCPU, "native.pmgr.p_cluster", "P Cluster");
    emitRange(cached.gpu, "native.pmgr.gpu", "GPU");
    return cached;
}

bool ioreportMatches(const std::string &group, const std::string &subgroup, const std::string &channel) {
    if (group == "Energy Model") {
        const bool cpuAggregate = endsWith(channel, "CPU Energy")
            || channel == "EACC_CPU"
            || ((startsWith(channel, "PACC") || startsWith(channel, "MACC")) && endsWith(channel, "_CPU"));
        return channel == "GPU Energy" || cpuAggregate
            || startsWith(channel, "ANE") || startsWith(channel, "DRAM") || startsWith(channel, "GPU SRAM");
    }
    if (group == "CPU Stats") {
        return subgroup == "CPU Core Performance States";
    }
    return group == "GPU Stats" && subgroup == "GPU Performance States";
}

void collectIOReport(std::vector<SSNativeMetric> &out) {
    PMGRFrequencies freqs = loadPMGRFrequencies(&out);
    CFDictionaryRef allChannels = IOReportCopyAllChannels(0, 0);
    if (!allChannels) {
        addTextMetric(out, "native.ioreport.status", "IOReport Status", "Raw", "IOReport unavailable", "NativeIOReport", "IOReportCopyAllChannels", true);
        return;
    }
    CFTypeRef channelsValue = dictValue(allChannels, "IOReportChannels");
    if (!channelsValue || CFGetTypeID(channelsValue) != CFArrayGetTypeID()) {
        addTextMetric(out, "native.ioreport.status", "IOReport Status", "Raw", "IOReport channel list unavailable", "NativeIOReport", "IOReportChannels", true);
        CFRelease(allChannels);
        return;
    }

    CFArrayRef channels = static_cast<CFArrayRef>(channelsValue);
    CFIndex totalCount = CFArrayGetCount(channels);
    CFMutableArrayRef selected = CFArrayCreateMutable(kCFAllocatorDefault, totalCount, &kCFTypeArrayCallBacks);
    for (CFIndex index = 0; index < totalCount; ++index) {
        CFDictionaryRef item = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(channels, index));
        std::string group = cfString(IOReportChannelGetGroup(item));
        std::string subgroup = cfString(IOReportChannelGetSubGroup(item));
        std::string channel = cfString(IOReportChannelGetChannelName(item));
        if (ioreportMatches(group, subgroup, channel)) {
            CFArrayAppendValue(selected, item);
        }
    }
    const CFIndex selectedCount = CFArrayGetCount(selected);

    CFMutableDictionaryRef subscriptionChannels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(allChannels), allChannels);
    CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, "IOReportChannels", kCFStringEncodingUTF8);
    CFDictionarySetValue(subscriptionChannels, key, selected);
    CFRelease(key);

    CFMutableDictionaryRef subscribedChannels = nullptr;
    IOReportSubscriptionRef subscription = IOReportCreateSubscription(nullptr, subscriptionChannels, &subscribedChannels, 0, nullptr);
    if (!subscription) {
        addTextMetric(out, "native.ioreport.status", "IOReport Status", "Raw", "IOReport subscription unavailable", "NativeIOReport", "IOReportCreateSubscription", true);
        CFRelease(subscriptionChannels);
        CFRelease(selected);
        CFRelease(allChannels);
        return;
    }

    CFDictionaryRef current = IOReportCreateSamples(subscription, subscriptionChannels, nullptr);
    using Clock = std::chrono::steady_clock;
    static CFDictionaryRef previous = nullptr;
    static Clock::time_point previousTime;
    Clock::time_point now = Clock::now();
    if (!current) {
        addTextMetric(out, "native.ioreport.status", "IOReport Status", "Raw", "IOReport sample unavailable", "NativeIOReport", "IOReportCreateSamples", true);
    } else if (!previous) {
        previous = current;
        previousTime = now;
        current = nullptr;
        addTextMetric(out, "native.ioreport.status", "IOReport Status", "Raw", "IOReport baseline captured", "NativeIOReport", "IOReportCreateSamples", true);
    } else {
        double elapsedMS = std::chrono::duration<double, std::milli>(now - previousTime).count();
        CFDictionaryRef delta = IOReportCreateSamplesDelta(previous, current, nullptr);
        CFRelease(previous);
        previous = current;
        previousTime = now;
        current = nullptr;

        if (!delta) {
            addTextMetric(out, "native.ioreport.status", "IOReport Status", "Raw", "IOReport delta unavailable", "NativeIOReport", "IOReportCreateSamplesDelta", true);
        } else {
            CFTypeRef deltaChannelsValue = dictValue(delta, "IOReportChannels");
            int emitted = 0;
            double cpuPower = 0;
            double eClusterPower = 0;
            double pClusterPower = 0;
            double gpuPower = 0;
            double anePower = 0;
            double dramPower = 0;
            double gpuSRAMPower = 0;
            bool sawCPUPower = false;
            bool sawEClusterPower = false;
            bool sawPClusterPower = false;
            bool sawGPUPower = false;
            bool sawANEPower = false;
            bool sawDRAMPower = false;
            bool sawGPUSRAMPower = false;
            std::vector<double> eFreqs;
            std::vector<double> pFreqs;
            std::vector<double> gpuFreqs;
            std::vector<double> gpuActive;
            if (deltaChannelsValue && CFGetTypeID(deltaChannelsValue) == CFArrayGetTypeID()) {
                CFArrayRef deltaChannels = static_cast<CFArrayRef>(deltaChannelsValue);
                CFIndex count = CFArrayGetCount(deltaChannels);
                for (CFIndex index = 0; index < count; ++index) {
                    CFDictionaryRef item = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(deltaChannels, index));
                    std::string group = cfString(IOReportChannelGetGroup(item));
                    std::string subgroup = cfString(IOReportChannelGetSubGroup(item));
                    std::string channel = cfString(IOReportChannelGetChannelName(item));
                    std::string unit = cfString(IOReportChannelGetUnitLabel(item));
                    unit.erase(std::remove_if(unit.begin(), unit.end(), ::isspace), unit.end());
                    if (group == "Energy Model") {
                        double mw = energyDeltaToMilliwatts(item, unit, elapsedMS);
                        if (mw < 0 || !std::isfinite(mw)) { continue; }
                        bool matchedPower = true;
                        if (channel == "GPU Energy") { sawGPUPower = true; gpuPower += mw; }
                        else if (endsWith(channel, "CPU Energy")) { sawCPUPower = true; cpuPower += mw; }
                        else if (channel == "EACC_CPU") { sawCPUPower = true; sawEClusterPower = true; eClusterPower += mw; cpuPower += mw; }
                        else if ((startsWith(channel, "PACC") || startsWith(channel, "MACC")) && endsWith(channel, "_CPU")) { sawCPUPower = true; sawPClusterPower = true; pClusterPower += mw; cpuPower += mw; }
                        else if (startsWith(channel, "ANE")) { sawANEPower = true; anePower += mw; }
                        else if (startsWith(channel, "DRAM")) { sawDRAMPower = true; dramPower += mw; }
                        else if (startsWith(channel, "GPU SRAM")) { sawGPUSRAMPower = true; gpuSRAMPower += mw; }
                        else { matchedPower = false; }
                        if (!matchedPower) { continue; }
                        addMetric(out, "native.ioreport.energy." + normalizedIDComponent(channel) + "_mw", channel, "Power", mw, "mW", "NativeIOReport", "Energy Model/" + channel, true);
                        emitted += 1;
                    } else if (group == "CPU Stats" && subgroup == "CPU Core Performance States") {
                        const bool isP = channel.find("PCPU") != std::string::npos;
                        const bool isE = channel.find("ECPU") != std::string::npos || channel.find("MCPU") != std::string::npos;
                        FrequencyEstimate estimate = estimateFrequency(item, isP ? freqs.pCPU : freqs.eCPU);
                        if (estimate.frequencyHz > 0) {
                            if (isP) { pFreqs.push_back(estimate.frequencyHz); }
                            if (isE) { eFreqs.push_back(estimate.frequencyHz); }
                        }
                    } else if (group == "GPU Stats" && subgroup == "GPU Performance States") {
                        FrequencyEstimate estimate = estimateFrequency(item, freqs.gpu);
                        if (estimate.frequencyHz > 0) {
                            gpuFreqs.push_back(estimate.frequencyHz);
                            gpuActive.push_back(estimate.activePercent);
                        }
                    }
                }
            }
            auto average = [](const std::vector<double> &values) -> double {
                if (values.empty()) { return 0; }
                double sum = 0;
                for (double value : values) { sum += value; }
                return sum / double(values.size());
            };
            if (sawCPUPower) { addMetric(out, "native.ioreport.cpu_power_mw", "CPU Power", "Power", cpuPower, "mW", "NativeIOReport", "Energy Model/*CPU*", true); }
            else { addTextMetric(out, "native.ioreport.cpu_power_status", "CPU Power Status", "Power", "CPU energy channels unavailable", "NativeIOReport", "Energy Model/*CPU*", true); }
            if (sawEClusterPower) { addMetric(out, "native.ioreport.e_cluster_power_mw", "E Cluster Power", "Power", eClusterPower, "mW", "NativeIOReport", "Energy Model/EACC_CPU", true); }
            if (sawPClusterPower) { addMetric(out, "native.ioreport.p_cluster_power_mw", "P Cluster Power", "Power", pClusterPower, "mW", "NativeIOReport", "Energy Model/PACC*_CPU", true); }
            if (sawGPUPower) { addMetric(out, "native.ioreport.gpu_power_mw", "GPU Power", "Power", gpuPower, "mW", "NativeIOReport", "Energy Model/GPU Energy", true); }
            if (sawANEPower) { addMetric(out, "native.ioreport.ane_power_mw", "ANE Power", "Power", anePower, "mW", "NativeIOReport", "Energy Model/ANE*", true); }
            if (sawDRAMPower) { addMetric(out, "native.ioreport.dram_power_mw", "DRAM Power", "Power", dramPower, "mW", "NativeIOReport", "Energy Model/DRAM*", true); }
            if (sawGPUSRAMPower) { addMetric(out, "native.ioreport.gpu_sram_power_mw", "GPU SRAM Power", "Power", gpuSRAMPower, "mW", "NativeIOReport", "Energy Model/GPU SRAM*", true); }
            double packagePower = cpuPower + gpuPower + anePower + dramPower;
            if (sawCPUPower || sawGPUPower || sawANEPower || sawDRAMPower) { addMetric(out, "native.ioreport.package_power_mw", "Package Power", "Power", packagePower, "mW", "NativeIOReport", "Energy Model aggregate", true); }
            double eAverage = average(eFreqs);
            double pAverage = average(pFreqs);
            double gpuAverage = average(gpuFreqs);
            double gpuActiveAverage = average(gpuActive);
            if (eAverage > 0) { addMetric(out, "native.ioreport.e_cluster_frequency_hz", "E Cluster Frequency", "Frequency", eAverage, "Hz", "NativeIOReport", "CPU Stats/ECPU", true); }
            if (pAverage > 0) { addMetric(out, "native.ioreport.p_cluster_frequency_hz", "P Cluster Frequency", "Frequency", pAverage, "Hz", "NativeIOReport", "CPU Stats/PCPU", true); }
            if (pAverage > 0 || eAverage > 0) { addMetric(out, "native.ioreport.cpu_frequency_hz", "CPU Frequency", "Frequency", pAverage > 0 ? pAverage : eAverage, "Hz", "NativeIOReport", "CPU Stats", true); }
            if (gpuAverage > 0) { addMetric(out, "native.ioreport.gpu_frequency_hz", "GPU Frequency", "Frequency", gpuAverage, "Hz", "NativeIOReport", "GPU Stats/GPUPH", true); }
            if (gpuActiveAverage > 0) { addMetric(out, "native.ioreport.gpu_residency_percent", "GPU Residency", "GPU", gpuActiveAverage, "%", "NativeIOReport", "GPU Stats/GPUPH", true); }
            addMetric(out, "native.ioreport.delta_ms", "IOReport Delta", "Raw", elapsedMS, "ms", "NativeIOReport", "IOReportCreateSamplesDelta", true);
            addMetric(out, "native.ioreport.selected_channels", "IOReport Channels", "Raw", double(selectedCount), "", "NativeIOReport", "IOReportChannels", true);
            addMetric(out, "native.ioreport.emitted_power_channels", "IOReport Power Channels", "Raw", emitted, "", "NativeIOReport", "Energy Model", true);
            CFRelease(delta);
        }
    }

    if (current) { CFRelease(current); }
    if (subscribedChannels) { CFRelease(subscribedChannels); }
    CFRelease(subscription);
    CFRelease(subscriptionChannels);
    CFRelease(selected);
    CFRelease(allChannels);
}

void collectIOReportStatus(std::vector<SSNativeMetric> &out) {
    void *handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!handle) {
        handle = dlopen("libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL);
    }
    if (!handle) {
        addTextMetric(out, "native.ioreport.status", "IOReport Status", "Raw", "IOReport unavailable", "NativeIOReport", "dlopen(IOReport)", true);
        return;
    }
    void *createSubscription = dlsym(handle, "IOReportCreateSubscription");
    void *createSamples = dlsym(handle, "IOReportCreateSamples");
    if (createSubscription && createSamples) {
        addTextMetric(out, "native.ioreport.status", "IOReport Status", "Raw", "IOReport symbols available", "NativeIOReport", "dlsym(IOReport)", true);
    } else {
        addTextMetric(out, "native.ioreport.status", "IOReport Status", "Raw", "IOReport symbols unavailable", "NativeIOReport", "dlsym(IOReport)", true);
    }
    dlclose(handle);
}

} // namespace

extern "C" int StellarScopeCollectNativeAdvanced(SSNativeMetric *metrics, int capacity) {
    if (!metrics || capacity <= 0) { return 0; }
    std::vector<SSNativeMetric> collected;
    collected.reserve(64);
    collectSMC(collected);
    collectSysctl(collected);
    collectIOReport(collected);
    int count = std::min<int>(capacity, int(collected.size()));
    for (int i = 0; i < count; ++i) {
        metrics[i] = collected[size_t(i)];
    }
    return count;
}

extern "C" const char *StellarScopeNativeMetricID(const SSNativeMetric *metric) {
    return metric ? metric->id : "";
}

extern "C" const char *StellarScopeNativeMetricTitle(const SSNativeMetric *metric) {
    return metric ? metric->title : "";
}

extern "C" const char *StellarScopeNativeMetricCategory(const SSNativeMetric *metric) {
    return metric ? metric->category : "";
}

extern "C" const char *StellarScopeNativeMetricUnit(const SSNativeMetric *metric) {
    return metric ? metric->unit : "";
}

extern "C" const char *StellarScopeNativeMetricSource(const SSNativeMetric *metric) {
    return metric ? metric->source : "";
}

extern "C" const char *StellarScopeNativeMetricRawKey(const SSNativeMetric *metric) {
    return metric ? metric->rawKey : "";
}

extern "C" const char *StellarScopeNativeMetricText(const SSNativeMetric *metric) {
    return metric ? metric->text : "";
}

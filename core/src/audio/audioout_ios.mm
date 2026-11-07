// iOS backend: a RemoteIO AudioUnit, which converts from the stream's rate to the hardware's. The audio session is set up here because
// nothing can play without it.
#include "audioout_impl.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#include <algorithm>
#include <atomic>
#include <string>
#include <vector>

namespace dect2 {

// The sound being played, kept for the app's audio scopes. One writer (the render callback); a reader may see a torn frame, which a scope never shows.
static constexpr uint32_t kTapFrames = 8192;
static float gTap[kTapFrames * 2];
static std::atomic<uint32_t> gTapWrite{0};

// before volume and mute: the scopes show the signal, not the slider
static void keepForScopes(const float* stereo, uint32_t frames) {
    uint32_t w = gTapWrite.load(std::memory_order_relaxed);
    for (uint32_t i = 0; i < frames; i++, w++) {
        gTap[(w % kTapFrames) * 2] = stereo[i * 2];
        gTap[(w % kTapFrames) * 2 + 1] = stereo[i * 2 + 1];
    }
    gTapWrite.store(w, std::memory_order_release);
}

static OSStatus renderCb(void* ref, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32, UInt32 nFrames, AudioBufferList* io) {
    static_cast<AudioOut::Impl*>(ref)->render((float*)io->mBuffers[0].mData, nFrames);
    return noErr;
}

// the last `frames` stereo frames played, oldest first
void audioIosRecent(float* stereo, int frames) {
    const uint32_t w = gTapWrite.load(std::memory_order_acquire);
    const uint32_t n = std::min<uint32_t>((uint32_t)frames, kTapFrames);
    for (uint32_t i = 0; i < n; i++) {
        const uint32_t at = (w - n + i) % kTapFrames;
        stereo[i * 2] = gTap[at * 2];
        stereo[i * 2 + 1] = gTap[at * 2 + 1];
    }
}

// The output most recently started: its real frames played, for the app's status line. Silence is not counted.
static std::atomic<AudioOut::Impl*> gActive{nullptr};
uint64_t audioIosPlayedFrames() {
    AudioOut::Impl* I = gActive.load();
    return I ? I->played.load() : 0;
}

// iOS routes audio itself (speaker, headphones, AirPlay): no device to choose
std::vector<std::string> audioListOutputs() { return {}; }

static bool activateSession() {
    NSError* e = nil;
    AVAudioSession* s = [AVAudioSession sharedInstance];
    if (![s setCategory:AVAudioSessionCategoryPlayback error:&e] || ![s setActive:YES error:&e]) {
        NSLog(@"OnAir audio session: %@", e);
        return false;
    }
    return true;
}

bool audioBackendStart(AudioOut::Impl* I, int rate) {
    if (!activateSession()) return false;
    I->tap = keepForScopes;
    AudioComponentDescription d = {kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent c = AudioComponentFindNext(nullptr, &d);
    AudioUnit unit = nullptr;
    if (!c || AudioComponentInstanceNew(c, &unit) != noErr) return false;
    AudioStreamBasicDescription f = {};
    f.mSampleRate = rate; f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mFramesPerPacket = 1; f.mChannelsPerFrame = 2; f.mBitsPerChannel = 32;
    f.mBytesPerFrame = 8; f.mBytesPerPacket = 8;
    OSStatus st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f);
    AURenderCallbackStruct cb = {renderCb, I};
    if (st == noErr) st = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
    if (st == noErr) st = AudioUnitInitialize(unit);
    if (st == noErr) st = AudioOutputUnitStart(unit);
    if (st != noErr) {
        NSLog(@"OnAir audio output: error %d", (int)st);
        AudioComponentInstanceDispose(unit);
        return false;
    }
    I->backend = unit;
    gActive = I;
    return true;
}

void audioBackendStop(AudioOut::Impl* I) {
    AudioUnit unit = (AudioUnit)I->backend;
    if (!unit) return;
    AudioOut::Impl* expected = I;
    gActive.compare_exchange_strong(expected, nullptr);
    AudioOutputUnitStop(unit);
    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
    I->backend = nullptr;
}

} // namespace dect2

// iOS capture: the microphone through AVAudioEngine, opened only while a transmission asks for it.
#include "audioin_impl.h"
#import <AVFoundation/AVFoundation.h>

namespace dect2 {

namespace {
struct Capture { AVAudioEngine* engine = nil; };
}

bool audioInMicStart(AudioIn::Impl* I, int rate, const std::string&, std::string& err) {
    NSError* e = nil;
    AVAudioSession* session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetoothHFP error:&e] ||
        ![session setActive:YES error:&e]) {
        err = "the microphone could not be started";
        return false;
    }
    auto* c = new Capture();
    c->engine = [AVAudioEngine new];
    AVAudioInputNode* input = c->engine.inputNode;
    AVAudioFormat* format = [input outputFormatForBus:0];
    if (format.sampleRate <= 0) {
        delete c;
        err = "no microphone is available";
        return false;
    }
    I->setResample(format.sampleRate, rate);
    [input installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer* buffer, AVAudioTime*) {
        if (buffer.floatChannelData) I->push(buffer.floatChannelData[0], buffer.frameLength, 1);
    }];
    if (![c->engine startAndReturnError:&e]) {
        [input removeTapOnBus:0];
        delete c;
        err = "the microphone could not be started";
        return false;
    }
    I->backend = c;
    return true;
}

void audioInMicStop(AudioIn::Impl* I) {
    auto* c = static_cast<Capture*>(I->backend);
    if (!c) return;
    [c->engine.inputNode removeTapOnBus:0];
    [c->engine stop];
    delete c;
    I->backend = nullptr;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];   // back to playing through whatever route was in use
}

std::vector<AudioInputDevice> audioInListMic() { return {}; }

} // namespace dect2

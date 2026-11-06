// iOS: the receiver only plays sound, so there is no microphone capture here. AudioIn's file and tone sources still work.
#include "audioin_impl.h"

namespace dect2 {

bool audioInMicStart(AudioIn::Impl*, int, const std::string&, std::string& err) {
    err = "No microphone input on iOS";
    return false;
}
void audioInMicStop(AudioIn::Impl*) {}
std::vector<AudioInputDevice> audioInListMic() { return {}; }

} // namespace dect2

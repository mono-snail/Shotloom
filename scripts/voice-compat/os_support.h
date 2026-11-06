#ifndef DESKCAPTURE_RNNOISE_OS_SUPPORT_H
#define DESKCAPTURE_RNNOISE_OS_SUPPORT_H
// RNNoise v0.2's vec headers retain the Opus spelling, but its archive
// supplies common.h with RNN_CLEAR and no os_support.h. Supply only that alias.
#include "common.h"
#ifndef OPUS_CLEAR
#define OPUS_CLEAR(destination, count) RNN_CLEAR(destination, count)
#endif
#endif

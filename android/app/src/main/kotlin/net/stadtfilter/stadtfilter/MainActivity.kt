package net.stadtfilter.stadtfilter

import com.ryanheise.audioservice.AudioServiceActivity

// Must extend AudioServiceActivity so the audio_service plugin shares the
// activity's Flutter engine (required for the media session / Android Auto).
class MainActivity : AudioServiceActivity()

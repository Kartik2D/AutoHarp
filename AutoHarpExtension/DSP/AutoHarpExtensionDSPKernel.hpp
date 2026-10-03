//
//  AutoHarpExtensionDSPKernel.hpp
//  AutoHarpExtension
//
//  Created by Kartik Vinayak on 9/11/26.
//

#pragma once

#import <AudioToolbox/AudioToolbox.h>
#import <CoreMIDI/MIDIMessages.h>

#import <cmath>
#import <cstring>
#import <algorithm>
#import <atomic>
#import <os/lock.h>
#import <vector>

#import "AutoHarpExtensionParameterAddresses.h"

static constexpr int kMIDIQueueSize = 32;
static constexpr int kPlayQ = 32;
struct PendingMIDI { bool on; uint8_t note; uint8_t vel; uint8_t ch; };
struct PlayCmd { uint8_t note; bool on; };

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static constexpr float kTwoPi = float(2.0 * M_PI);
static constexpr int kMaxPartials = 5;
static constexpr int kStrumVoices = 24;

static constexpr int kMajorIntervals[] = {0, 4, 7};
static constexpr int kMinorIntervals[] = {0, 3, 7};
static constexpr int kMaj7Intervals[] = {0, 4, 7, 11};
static constexpr int kMin7Intervals[] = {0, 3, 7, 10};
static constexpr int kDom7Intervals[] = {0, 4, 7, 10};
static constexpr int kAugIntervals[] = {0, 4, 8};
static constexpr int kDimIntervals[] = {0, 3, 6};
static constexpr int kSus2Intervals[] = {0, 2, 7};
static constexpr int kSus4Intervals[] = {0, 5, 7};
static constexpr int kSingleInterval[] = {0};

inline std::atomic<int>& metroRemainSamples() {
    static std::atomic<int> n{1};
    return n;
}

// INVARIANTS — do not "simplify" these away (the click comes back):
// 1. UI only enqueues. process() applies at the buffer start, then generates.
// 2. One instrument: retune changes targets only. Do not restart the envelope. No second chord copy.
// 3. Never jump the output: slew amp/increment. Never zero phase/filt on a live voice.
// 4. MIDI is queued here; flush off the audio thread.
class AutoHarpExtensionDSPKernel {
public:
    void initialize(double inSampleRate) {
        mSampleRate = inSampleRate;
        updateEnvRates();
        updateIncrements();
        for (int i = 0; i < kMaxPartials; ++i) { mIncrement[i] = mTargetInc[i]; }
    }

    void deInitialize() {
        mScratch.clear();
    }

    void prepareOutput(UInt32 channelCount, AUAudioFrameCount maxFrames) {
        mMaxFramesToRender = maxFrames;
        mScratch.assign(channelCount, std::vector<float>(maxFrames, 0.f));
    }

    float* outputBufferPointer(UInt32 channel) {
        if (channel >= mScratch.size()) { return nullptr; }
        return mScratch[channel].data();
    }

    bool isBypassed() {
        return mBypassed;
    }

    void setBypass(bool shouldBypass) {
        mBypassed = shouldBypass;
    }

    void setParameter(AUParameterAddress address, AUValue value) {
        switch (address) {
            case AutoHarpExtensionParameterAddress::midiNoteNumber:
                mNextNoteToSend = uint8_t(value);
                break;
            case AutoHarpExtensionParameterAddress::chordQuality:
                mQuality = std::clamp(int(value + 0.5f), 0, 8);
                break;
            case AutoHarpExtensionParameterAddress::sendNote: {
                bool shouldGate = value >= 0.5f;
                if (shouldGate && !mParamGated) {
                    mParamGated = true;
                    mMIDIVoice = false;
                    noteOn(mNextNoteToSend);
                } else if (!shouldGate && mParamGated) {
                    mParamGated = false;
                    noteOff(mCurrentNote);
                }
                break;
            }
            case AutoHarpExtensionParameterAddress::layout:
                mLayout = std::clamp(int(value + 0.5f), 0, 1);
                break;
            case AutoHarpExtensionParameterAddress::coloring:
                mColoring = std::clamp(int(value + 0.5f), 0, 1);
                break;
            case AutoHarpExtensionParameterAddress::metroOn: {
                bool on = value >= 0.5f;
                if (on && !mMetroOn) {
                    mMetroCount = 1;
                    metroRemainSamples().store(1, std::memory_order_relaxed);
                }
                mMetroOn = on;
                break;
            }
            case AutoHarpExtensionParameterAddress::metroBPM:
                mMetroBPM = std::clamp(value, 40.f, 240.f);
                break;
            case AutoHarpExtensionParameterAddress::metroWave:
                mMetroWave = std::clamp(int(value + 0.5f), 0, 3);
                break;
            case AutoHarpExtensionParameterAddress::metroAttack:
                mMetroAttackMs = value;
                updateEnvRates();
                break;
            case AutoHarpExtensionParameterAddress::metroRelease:
                mMetroReleaseMs = value;
                updateEnvRates();
                break;
            case AutoHarpExtensionParameterAddress::metroSustain:
                mMetroSustain = std::clamp(value, 0.f, 1.f);
                break;
            case AutoHarpExtensionParameterAddress::metroVolume:
                mMetroVolume = std::clamp(value, 0.f, 1.f);
                break;
            case AutoHarpExtensionParameterAddress::metroSync:
                mMetroSync = value >= 0.5f;
                break;
            case AutoHarpExtensionParameterAddress::strumNote:
                mStrumNote = uint8_t(value);
                break;
            case AutoHarpExtensionParameterAddress::strumGate: {
                bool on = value >= 0.5f;
                if (on && !mStrumGated) {
                    mStrumGated = true;
                    strumOn(mStrumNote);
                } else if (!on && mStrumGated) {
                    mStrumGated = false;
                    strumOffAll();
                }
                break;
            }
            case AutoHarpExtensionParameterAddress::droneWave:
                mDroneWave = std::clamp(int(value + 0.5f), 0, 3);
                break;
            case AutoHarpExtensionParameterAddress::droneAttack:
                mDroneAttackMs = value;
                updateEnvRates();
                break;
            case AutoHarpExtensionParameterAddress::droneRelease:
                mDroneReleaseMs = value;
                updateEnvRates();
                break;
            case AutoHarpExtensionParameterAddress::droneSustain:
                mDroneSustain = std::clamp(value, 0.f, 1.f);
                break;
            case AutoHarpExtensionParameterAddress::droneVolume:
                mDroneVolume = std::clamp(value, 0.f, 1.f);
                break;
            case AutoHarpExtensionParameterAddress::strumWave:
                mStrumWave = std::clamp(int(value + 0.5f), 0, 3);
                break;
            case AutoHarpExtensionParameterAddress::strumAttack:
                mStrumAttackMs = value;
                updateEnvRates();
                break;
            case AutoHarpExtensionParameterAddress::strumRelease:
                mStrumReleaseMs = value;
                updateEnvRates();
                break;
            case AutoHarpExtensionParameterAddress::strumSustain:
                mStrumSustain = std::clamp(value, 0.f, 1.f);
                break;
            case AutoHarpExtensionParameterAddress::strumVolume:
                mStrumVolume = std::clamp(value, 0.f, 1.f);
                break;
        }
    }

    AUValue getParameter(AUParameterAddress address) {
        switch (address) {
            case AutoHarpExtensionParameterAddress::midiNoteNumber:
                return AUValue(mNextNoteToSend);
            case AutoHarpExtensionParameterAddress::sendNote:
                return mParamGated ? 1.f : 0.f;
            case AutoHarpExtensionParameterAddress::chordQuality:
                return AUValue(mQuality);
            case AutoHarpExtensionParameterAddress::strumNote:
                return AUValue(mStrumNote);
            case AutoHarpExtensionParameterAddress::strumGate:
                return mStrumGated ? 1.f : 0.f;
            case AutoHarpExtensionParameterAddress::layout:
                return AUValue(mLayout);
            case AutoHarpExtensionParameterAddress::coloring:
                return AUValue(mColoring);
            case AutoHarpExtensionParameterAddress::metroOn:
                return mMetroOn ? 1.f : 0.f;
            case AutoHarpExtensionParameterAddress::metroBPM:
                return mMetroBPM;
            case AutoHarpExtensionParameterAddress::metroWave:
                return AUValue(mMetroWave);
            case AutoHarpExtensionParameterAddress::metroAttack:
                return mMetroAttackMs;
            case AutoHarpExtensionParameterAddress::metroRelease:
                return mMetroReleaseMs;
            case AutoHarpExtensionParameterAddress::metroSustain:
                return mMetroSustain;
            case AutoHarpExtensionParameterAddress::metroVolume:
                return mMetroVolume;
            case AutoHarpExtensionParameterAddress::metroSync:
                return mMetroSync ? 1.f : 0.f;
            case AutoHarpExtensionParameterAddress::droneWave:
                return AUValue(mDroneWave);
            case AutoHarpExtensionParameterAddress::droneAttack:
                return mDroneAttackMs;
            case AutoHarpExtensionParameterAddress::droneRelease:
                return mDroneReleaseMs;
            case AutoHarpExtensionParameterAddress::droneSustain:
                return mDroneSustain;
            case AutoHarpExtensionParameterAddress::droneVolume:
                return mDroneVolume;
            case AutoHarpExtensionParameterAddress::strumWave:
                return AUValue(mStrumWave);
            case AutoHarpExtensionParameterAddress::strumAttack:
                return mStrumAttackMs;
            case AutoHarpExtensionParameterAddress::strumRelease:
                return mStrumReleaseMs;
            case AutoHarpExtensionParameterAddress::strumSustain:
                return mStrumSustain;
            case AutoHarpExtensionParameterAddress::strumVolume:
                return mStrumVolume;
            default: return 0.f;
        }
    }

    double secondsToNextBeat() {
        return double(std::max(0, metroRemainSamples().load(std::memory_order_relaxed))) / mSampleRate;
    }

    AUAudioFrameCount maximumFramesToRender() const {
        return mMaxFramesToRender;
    }

    void setMaximumFramesToRender(const AUAudioFrameCount &maxFrames) {
        mMaxFramesToRender = maxFrames;
    }

    void setMIDIOutputEventBlock(AUMIDIEventListBlock midiOutBlock) {
        mMIDIOutBlock = midiOutBlock;
    }

    void setMIDI1OutputEventBlock(AUMIDIOutputEventBlock midiOutBlock) {
        mMIDI1OutBlock = midiOutBlock;
    }

    void applyLiveChord() {
        os_unfair_lock_lock(&mCmdLock);
        if (mParamGated) { mPendingRetune = true; }
        os_unfair_lock_unlock(&mCmdLock);
    }

    void setDroneEnabled(bool on) {
        if (on == mDroneEnabled) { return; }
        mDroneEnabled = on;
        if (!on) {
            if (!mMIDIVoice) { releaseChordMIDI(); }
            mEnvState = Idle;
            mEnv = 0.f;
            mAmp = 0.f;
        } else if (mParamGated && !mMIDIVoice) {
            retune();
            sendChordMIDI();
        }
    }

    void setSplitMIDI(bool split) {
        if (split == mSplitMIDI) { return; }
        if (mHeldChordCount) { releaseChordMIDI(); }
        for (int i = 0; i < kStrumVoices; ++i) {
            if (mStrum[i].midiOn) { sendMIDI(false, mStrum[i].note, 0, false); }
        }
        memset(mMidiHold, 0, sizeof(mMidiHold));
        mSplitMIDI = split;
        if (mParamGated && mDroneEnabled && !mMIDIVoice) { sendChordMIDI(); }
        for (int i = 0; i < kStrumVoices; ++i) {
            if (mStrum[i].midiOn) { sendMIDI(true, mStrum[i].note, midiVel(mStrumVolume), false); }
        }
    }

    MIDIProtocolID AudioUnitMIDIProtocol() const {
        return kMIDIProtocol_1_0;
    }

    void process(AUEventSampleTime bufferStartTime, AUAudioFrameCount frameCount, AudioBufferList *out, AUAudioFrameCount frameOffset) {
        (void)bufferStartTime;
        applyPending();
        if (mBypassed) {
            writeSilence(out, frameCount, frameOffset);
        } else {
            for (AUAudioFrameCount i = 0; i < frameCount; ++i) {
                writeSample(out, frameOffset + i, nextSample());
            }
        }
    }

    void flushMIDI() {
        PendingMIDI midi[kMIDIQueueSize];
        int count = drainMIDI(midi);
        emitMIDI(midi, count);
    }

    void handleOneEvent(AUEventSampleTime now, AURenderEvent const *event) {
        switch (event->head.eventType) {
            case AURenderEventParameter: {
                handleParameterEvent(now, event->parameter);
                break;
            }
            case AURenderEventMIDIEventList: {
                handleMIDIEventList(now, &event->MIDIEventsList);
                break;
            }
            default:
                break;
        }
    }

    void handleMIDIEventList(AUEventSampleTime now, AUMIDIEventList const* midiEvent) {
        (void)now;
        auto visitor = [] (void* context, MIDITimeStamp timeStamp, MIDIUniversalMessage message) {
            (void)timeStamp;
            auto thisObject = static_cast<AutoHarpExtensionDSPKernel *>(context);

            switch (message.type) {
                case kMIDIMessageTypeChannelVoice2: {
                    switch (message.channelVoice2.status) {
                        case kMIDICVStatusNoteOn:
                            if (message.channelVoice2.note.velocity > 0) {
                                thisObject->mMIDIVoice = true;
                                thisObject->noteOn(message.channelVoice2.note.number);
                            } else {
                                thisObject->noteOff(message.channelVoice2.note.number);
                            }
                            break;
                        case kMIDICVStatusNoteOff:
                            thisObject->noteOff(message.channelVoice2.note.number);
                            break;
                        default:
                            break;
                    }
                    break;
                }
                case kMIDIMessageTypeChannelVoice1: {
                    switch (message.channelVoice1.status) {
                        case kMIDICVStatusNoteOn:
                            if (message.channelVoice1.note.velocity > 0) {
                                thisObject->mMIDIVoice = true;
                                thisObject->noteOn(message.channelVoice1.note.number);
                            } else {
                                thisObject->noteOff(message.channelVoice1.note.number);
                            }
                            break;
                        case kMIDICVStatusNoteOff:
                            thisObject->noteOff(message.channelVoice1.note.number);
                            break;
                        default:
                            break;
                    }
                    break;
                }
                default:
                    break;
            }
        };
        MIDIEventListForEachEvent(&midiEvent->eventList, visitor, this);
    }

    void strumVoiceOn(uint8_t note) { enqueuePlay(true, note); }
    void strumVoiceOff(uint8_t note) { enqueuePlay(false, note); }

    void handleParameterEvent(AUEventSampleTime now, AUParameterEvent const& parameterEvent) {
        (void)now;
        setParameter(parameterEvent.parameterAddress, parameterEvent.value);
    }

private:
    enum EnvState { Idle, Attack, Sustain, Release };
    struct StrumVoice {
        float phase = 0.f;
        float increment = 0.f;
        float env = 0.f;
        float amp = 0.f;
        float filt = 0.f;
        EnvState state = Idle;
        uint8_t note = 255;
        bool midiOn = false;
    };

    void applyChord() {
        if (mMIDIVoice) {
            retune();
            return;
        }
        releaseChordMIDI();
        if (mDroneEnabled) {
            retune();
            sendChordMIDI();
        } else {
            mEnvState = Idle;
            mEnv = 0.f;
            mAmp = 0.f;
        }
    }

    void noteOn(uint8_t note) {
        mNextNoteToSend = note;
        os_unfair_lock_lock(&mCmdLock);
        mPendingRetune = true;
        os_unfair_lock_unlock(&mCmdLock);
    }

    void enqueuePlay(bool on, uint8_t note) {
        os_unfair_lock_lock(&mCmdLock);
        if (mPlayN < kPlayQ) { mPlayQ[mPlayN++] = {note, on}; }
        os_unfair_lock_unlock(&mCmdLock);
    }

    void applyPending() {
        PlayCmd local[kPlayQ];
        int n = 0;
        bool retune = false;
        os_unfair_lock_lock(&mCmdLock);
        retune = mPendingRetune;
        mPendingRetune = false;
        n = mPlayN;
        for (int i = 0; i < n; ++i) { local[i] = mPlayQ[i]; }
        mPlayN = 0;
        os_unfair_lock_unlock(&mCmdLock);
        if (retune) {
            mCurrentNote = mNextNoteToSend;
            applyChord();
        }
        for (int i = 0; i < n; ++i) {
            if (local[i].on) { strumOn(local[i].note); } else { strumOff(local[i].note); }
        }
    }

    void retune() {
        bool start = mEnvState == Idle;
        updateIncrements();
        if (start) {
            for (int i = 0; i < kMaxPartials; ++i) { mIncrement[i] = mTargetInc[i]; }
            mEnv = 0.f;
            mAmp = 0.f;
            mEnvState = Attack;
        }
    }

    void noteOff(uint8_t note) {
        if (note != mCurrentNote) { return; }
        if (!mMIDIVoice) { releaseChordMIDI(); }
        if (mEnvState != Idle) { mEnvState = Release; }
    }

    uint8_t midiVel(float volume) const {
        return uint8_t(std::clamp(volume * 127.f + 0.5f, 1.f, 127.f));
    }

    uint8_t midiCh(bool drone) const { return (mSplitMIDI && !drone) ? 1 : 0; }

    void sendMIDI(bool on, uint8_t note, uint8_t vel, bool drone) {
        uint8_t ch = midiCh(drone);
        uint8_t &hold = mMidiHold[ch][note];
        os_unfair_lock_lock(&mMIDILock);
        if (on) {
            if (hold < 255) { hold++; }
            if (hold != 1) {
                if (mMIDIQueueCount + 1 < kMIDIQueueSize) {
                    mMIDIQueue[mMIDIQueueCount++] = {false, note, 0, ch};
                    mMIDIQueue[mMIDIQueueCount++] = {true, note, vel, ch};
                }
                os_unfair_lock_unlock(&mMIDILock);
                return;
            }
        } else {
            if (hold == 0) {
                os_unfair_lock_unlock(&mMIDILock);
                return;
            }
            hold--;
            if (hold != 0) {
                os_unfair_lock_unlock(&mMIDILock);
                return;
            }
        }
        if (mMIDIQueueCount < kMIDIQueueSize) {
            mMIDIQueue[mMIDIQueueCount++] = {on, note, on ? vel : uint8_t(0), ch};
        }
        os_unfair_lock_unlock(&mMIDILock);
    }

    int drainMIDI(PendingMIDI *local) {
        os_unfair_lock_lock(&mMIDILock);
        int count = mMIDIQueueCount;
        for (int i = 0; i < count; ++i) { local[i] = mMIDIQueue[i]; }
        mMIDIQueueCount = 0;
        os_unfair_lock_unlock(&mMIDILock);
        return count;
    }

    void emitMIDI(const PendingMIDI *local, int count) {
        for (int i = 0; i < count; ++i) {
            uint8_t bytes[3] = {
                uint8_t((local[i].on ? 0x90 : 0x80) | (local[i].ch & 0x0F)),
                local[i].note,
                local[i].vel
            };
            if (mMIDI1OutBlock) {
                mMIDI1OutBlock(AUEventSampleTimeImmediate, 0, 3, bytes);
            }
            if (mMIDIOutBlock) {
                auto message = local[i].on
                    ? MIDI2NoteOn(0, local[i].ch, local[i].note, 0, 0, uint16_t(local[i].vel) << 9)
                    : MIDI2NoteOff(0, local[i].ch, local[i].note, 0, 0, 0);
                MIDIEventList eventList = {};
                MIDIEventPacket *packet = MIDIEventListInit(&eventList, kMIDIProtocol_2_0);
                packet = MIDIEventListAdd(&eventList, sizeof(MIDIEventList), packet, 0, 2, (UInt32 *)&message);
                mMIDIOutBlock(AUEventSampleTimeImmediate, 0, &eventList);
            }
        }
    }

    void voicing(const int *&iv, int &n) const {
        if (mMIDIVoice) {
            iv = kSingleInterval;
            n = 1;
            return;
        }
        const int *base = kMajorIntervals;
        int bn = 3;
        switch (mQuality) {
            case 1: base = kMinorIntervals; bn = 3; break;
            case 2: base = kMaj7Intervals; bn = 4; break;
            case 3: base = kMin7Intervals; bn = 4; break;
            case 4: base = kDom7Intervals; bn = 4; break;
            case 5: base = kAugIntervals; bn = 3; break;
            case 6: base = kDimIntervals; bn = 3; break;
            case 7: base = kSus2Intervals; bn = 3; break;
            case 8: base = kSus4Intervals; bn = 3; break;
            default: break;
        }
        n = 0;
        mVoiceIntervals[n++] = -12;
        for (int i = 0; i < bn; ++i) { mVoiceIntervals[n++] = base[i]; }
        iv = mVoiceIntervals;
    }

    void sendChordMIDI() {
        if (!mDroneEnabled) { return; }
        const int *iv = nullptr;
        int n = 0;
        voicing(iv, n);
        mHeldChordCount = 0;
        for (int i = 0; i < n; ++i) {
            int raw = int(mCurrentNote) + iv[i];
            if (raw < 0 || raw > 127) { continue; }
            uint8_t note = uint8_t(raw);
            sendMIDI(true, note, midiVel(mDroneVolume), true);
            mHeldChordNotes[mHeldChordCount++] = note;
        }
    }

    void releaseChordMIDI() {
        for (int i = 0; i < mHeldChordCount; ++i) {
            sendMIDI(false, mHeldChordNotes[i], 0, true);
        }
        mHeldChordCount = 0;
    }

    float incrementForNote(uint8_t note) const {
        float freq = 440.f * std::pow(2.f, (float(note) - 69.f) / 12.f);
        return kTwoPi * freq / float(mSampleRate);
    }

    void strumOn(uint8_t note) {
        int match = -1, idle = -1, steal = -1;
        float stealEnv = 2.f;
        for (int i = 0; i < kStrumVoices; ++i) {
            auto &v = mStrum[i];
            if (v.note == note && v.state != Idle) { match = i; break; }
            if (v.state == Idle) { if (idle < 0) idle = i; }
            else if (v.env < stealEnv) { steal = i; stealEnv = v.env; }
        }
        int slot = match >= 0 ? match : (idle >= 0 ? idle : (steal >= 0 ? steal : 0));
        if (mStrum[slot].midiOn) { sendMIDI(false, mStrum[slot].note, 0, false); }
        mStrum[slot].note = note;
        mStrum[slot].increment = incrementForNote(note);
        if (match < 0) {
            mStrum[slot].phase = zeroPhase(mStrumWave);
            mStrum[slot].amp = 0.f;
        }
        mStrum[slot].env = 0.f;
        mStrum[slot].state = Attack;
        mStrum[slot].midiOn = true;
        sendMIDI(true, note, midiVel(mStrumVolume), false);
    }

    void strumOff(uint8_t note) {
        for (int i = 0; i < kStrumVoices; ++i) {
            if (mStrum[i].note != note || mStrum[i].state == Idle) { continue; }
            mStrum[i].state = Release;
        }
    }

    void strumOffAll() {
        for (int i = 0; i < kStrumVoices; ++i) {
            if (mStrum[i].state != Idle) { mStrum[i].state = Release; }
        }
    }

    bool decayStrum(StrumVoice &v, float target) {
        v.env = target + (v.env - target) * mStrumDecayMul;
        if (v.env > target + 0.001f) { return false; }
        v.env = target;
        if (target > 0.f) { return false; }
        if (v.midiOn) {
            sendMIDI(false, v.note, 0, false);
            v.midiOn = false;
        }
        v.state = Idle;
        return true;
    }

    float renderStrum() {
        float mix = 0.f;
        for (int i = 0; i < kStrumVoices; ++i) {
            auto &v = mStrum[i];
            if (v.state == Idle) { continue; }
            switch (v.state) {
                case Attack:
                    v.env += mStrumAttackInc;
                    if (v.env >= 1.f) {
                        v.env = 1.f;
                        v.state = Sustain;
                    }
                    break;
                case Sustain:
                    if (decayStrum(v, mStrumSustain)) { continue; }
                    break;
                case Release:
                    if (decayStrum(v, 0.f)) { continue; }
                    break;
                default:
                    break;
            }
            v.amp += (v.env - v.amp) * mDeclick;
            float x = osc(v.phase, mStrumWave) * v.amp;
            v.filt += 0.22f * (x - v.filt);
            mix += v.filt;
            v.phase += v.increment;
            if (v.phase >= kTwoPi) { v.phase -= kTwoPi; }
        }
        return mix * mStrumVolume;
    }

    void metroClick() {
        mMetro.increment = incrementForNote(100);
        mMetro.phase = 0.f;
        mMetro.filt = 0.f;
        mMetro.env = 0.f;
        mMetro.state = Attack;
    }

    float renderMetro() {
        if (mMetroOn) {
            if (--mMetroCount <= 0) {
                metroClick();
                mMetroCount = int(std::max(1.0, 60.0 / double(mMetroBPM) * mSampleRate));
            }
            metroRemainSamples().store(mMetroCount, std::memory_order_relaxed);
        }
        auto &v = mMetro;
        if (v.state == Idle) { return 0.f; }
        switch (v.state) {
            case Attack:
                v.env += mMetroAttackInc;
                if (v.env >= 1.f) {
                    v.env = 1.f;
                    v.state = Sustain;
                }
                break;
            case Sustain:
                if (decayMetro(mMetroSustain)) { return 0.f; }
                break;
            case Release:
                if (decayMetro(0.f)) { return 0.f; }
                break;
            default:
                break;
        }
        float x = osc(v.phase, mMetroWave) * v.env;
        v.filt += 0.22f * (x - v.filt);
        v.phase += v.increment;
        if (v.phase >= kTwoPi) { v.phase -= kTwoPi; }
        return v.filt * mMetroVolume;
    }

    bool decayMetro(float target) {
        mMetro.env = target + (mMetro.env - target) * mMetroDecayMul;
        if (mMetro.env > target + 0.001f) { return false; }
        mMetro.env = target;
        if (target > 0.f) { return false; }
        mMetro.state = Idle;
        return true;
    }

    float zeroPhase(int shape) const {
        switch (shape) {
            case 1: return float(M_PI) * 0.5f;
            case 2: return float(M_PI);
            default: return 0.f;
        }
    }

    float osc(float phase, int shape) const {
        switch (shape) {
            case 1: {
                float t = phase / kTwoPi;
                return t < 0.5f ? (4.f * t - 1.f) : (3.f - 4.f * t);
            }
            case 2:
                return phase / kTwoPi * 2.f - 1.f;
            case 3:
                return phase < float(M_PI) ? 1.f : -1.f;
            default:
                return std::sin(phase);
        }
    }

    void updateEnvRates() {
        mAttackInc = 1.f / std::max(1.f, mDroneAttackMs * 0.001f * float(mSampleRate));
        mReleaseInc = 1.f / std::max(1.f, mDroneReleaseMs * 0.001f * float(mSampleRate));
        mStrumAttackInc = 1.f / std::max(1.f, mStrumAttackMs * 0.001f * float(mSampleRate));
        mStrumDecayMul = 1.f - 6.9f / std::max(1.f, mStrumReleaseMs * 0.001f * float(mSampleRate));
        mStrumDecayMul = std::clamp(mStrumDecayMul, 0.f, 0.9999f);
        mMetroAttackInc = 1.f / std::max(1.f, mMetroAttackMs * 0.001f * float(mSampleRate));
        mMetroDecayMul = 1.f - 6.9f / std::max(1.f, mMetroReleaseMs * 0.001f * float(mSampleRate));
        mMetroDecayMul = std::clamp(mMetroDecayMul, 0.f, 0.9999f);
        mDeclick = 1.f - std::exp(-1.f / std::max(1.f, 0.005f * float(mSampleRate)));
    }

    void updateIncrements() {
        const int *iv = nullptr;
        int n = 0;
        voicing(iv, n);
        mActivePartials = n;
        for (int i = 0; i < n; ++i) {
            float freq = 440.f * std::pow(2.f, (float(mCurrentNote + iv[i]) - 69.f) / 12.f);
            mTargetInc[i] = kTwoPi * freq / float(mSampleRate);
        }
    }

    float nextSample() {
        float chord = 0.f;
        if (mDroneEnabled && mEnvState != Idle) {
            switch (mEnvState) {
                case Attack: {
                    float target = mDroneSustain;
                    if (target <= 0.f) {
                        mEnv = 0.f;
                        mEnvState = Sustain;
                        break;
                    }
                    mEnv += mAttackInc * target;
                    if (mEnv >= target) {
                        mEnv = target;
                        mEnvState = Sustain;
                    }
                    break;
                }
                case Sustain:
                    mEnv = mDroneSustain;
                    break;
                case Release:
                    mEnv -= mReleaseInc;
                    if (mEnv <= 0.f) {
                        mEnv = 0.f;
                        mEnvState = Idle;
                    }
                    break;
                default:
                    break;
            }
            mAmp += (mEnv - mAmp) * mDeclick;
            if (mEnvState != Idle) {
                for (int i = 0; i < kMaxPartials; ++i) {
                    float want = i < mActivePartials ? 1.f : 0.f;
                    if (mVoiceAmp[i] < 0.001f && want > 0.f) {
                        mPhase[i] = zeroPhase(mDroneWave);
                        mIncrement[i] = mTargetInc[i];
                    }
                    mVoiceAmp[i] += (want - mVoiceAmp[i]) * mDeclick;
                    mIncrement[i] += (mTargetInc[i] - mIncrement[i]) * mDeclick;
                    chord += osc(mPhase[i], mDroneWave) * mVoiceAmp[i];
                    mPhase[i] += mIncrement[i];
                    if (mPhase[i] >= kTwoPi) { mPhase[i] -= kTwoPi; }
                }
                chord *= (mDroneVolume / float(kMaxPartials)) * mAmp;
            }
        }
        return chord + renderStrum() + renderMetro();
    }

    void writeSample(AudioBufferList *out, AUAudioFrameCount frame, float sample) {
        if (out == nullptr) { return; }
        for (UInt32 ch = 0; ch < out->mNumberBuffers; ++ch) {
            auto *dest = static_cast<float *>(out->mBuffers[ch].mData);
            if (dest == nullptr) { continue; }
            UInt32 nch = out->mBuffers[ch].mNumberChannels;
            if (nch <= 1) {
                dest[frame] = sample;
            } else {
                for (UInt32 c = 0; c < nch; ++c) {
                    dest[frame * nch + c] = sample;
                }
            }
        }
    }

    void writeSilence(AudioBufferList *out, AUAudioFrameCount frameCount, AUAudioFrameCount frameOffset) {
        for (AUAudioFrameCount i = 0; i < frameCount; ++i) {
            writeSample(out, frameOffset + i, 0.f);
        }
    }

    AUMIDIEventListBlock mMIDIOutBlock = nullptr;
    AUMIDIOutputEventBlock mMIDI1OutBlock = nullptr;
    PendingMIDI mMIDIQueue[kMIDIQueueSize] = {};
    int mMIDIQueueCount = 0;
    os_unfair_lock mMIDILock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock mCmdLock = OS_UNFAIR_LOCK_INIT;
    PlayCmd mPlayQ[kPlayQ] = {};
    int mPlayN = 0;
    bool mPendingRetune = false;
    uint8_t mMidiHold[2][128] = {};

    double mSampleRate = 44100.0;
    bool mBypassed = false;
    AUAudioFrameCount mMaxFramesToRender = 1024;

    bool mParamGated = false;
    bool mMIDIVoice = false;
    bool mDroneEnabled = true;
    bool mSplitMIDI = false;
    mutable int mVoiceIntervals[kMaxPartials] = {};
    int mQuality = 0;
    int mLayout = 0;
    int mColoring = 0;
    uint8_t mNextNoteToSend = 60;
    uint8_t mCurrentNote = 60;
    int mActivePartials = 1;
    uint8_t mHeldChordNotes[kMaxPartials] = {};
    int mHeldChordCount = 0;

    float mPhase[kMaxPartials] = {};
    float mIncrement[kMaxPartials] = {};
    float mTargetInc[kMaxPartials] = {};
    float mVoiceAmp[kMaxPartials] = {};
    float mEnv = 0.f;
    float mAmp = 0.f;
    float mAttackInc = 0.f;
    float mReleaseInc = 0.f;
    float mStrumAttackInc = 0.f;
    float mStrumDecayMul = 0.f;
    float mDeclick = 0.05f;
    EnvState mEnvState = Idle;

    int mDroneWave = 0;
    float mDroneAttackMs = 5.f;
    float mDroneReleaseMs = 150.f;
    float mDroneSustain = 1.f;
    float mDroneVolume = 0.3f;
    int mStrumWave = 2;
    float mStrumAttackMs = 2.f;
    float mStrumReleaseMs = 2500.f;
    float mStrumSustain = 0.f;
    float mStrumVolume = 0.18f;
    bool mMetroOn = false;
    float mMetroBPM = 120.f;
    int mMetroWave = 3;
    float mMetroAttackMs = 1.f;
    float mMetroReleaseMs = 40.f;
    float mMetroSustain = 0.f;
    float mMetroVolume = 0.35f;
    bool mMetroSync = true;
    float mMetroAttackInc = 0.f;
    float mMetroDecayMul = 0.f;
    int mMetroCount = 1;
    StrumVoice mMetro;

    bool mStrumGated = false;
    uint8_t mStrumNote = 72;
    StrumVoice mStrum[kStrumVoices];

    std::vector<std::vector<float>> mScratch;
};

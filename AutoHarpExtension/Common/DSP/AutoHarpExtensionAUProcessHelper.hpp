//
//  AutoHarpExtensionAUProcessHelper.hpp
//  AutoHarpExtension
//
//  Created by Kartik Vinayak on 9/11/26.
//

#pragma once

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#include <algorithm>
#include "AutoHarpExtensionDSPKernel.hpp"

//MARK:- AUProcessHelper Utility Class
class AUProcessHelper
{
public:
    AUProcessHelper(AutoHarpExtensionDSPKernel& kernel)
    : mKernel{kernel} {}

    /**
     This function handles the event list processing and rendering loop for you.
     Call it inside your internalRenderBlock.
     */
    void processWithEvents(AudioTimeStamp const *timestamp, AUAudioFrameCount frameCount, AURenderEvent const *events, AudioBufferList *outputData) {

        AUEventSampleTime now = AUEventSampleTime(timestamp->mSampleTime);
        AUAudioFrameCount framesRemaining = frameCount;
        AUAudioFrameCount frameOffset = 0;
        AURenderEvent const *nextEvent = events;

        while (framesRemaining > 0) {
            if (nextEvent == nullptr) {
                mKernel.process(now, framesRemaining, outputData, frameOffset);
                mKernel.flushMIDI();
                return;
            }

            auto timeZero = AUEventSampleTime(0);
            auto headEventTime = nextEvent->head.eventSampleTime;
            AUAudioFrameCount framesThisSegment = AUAudioFrameCount(std::max(timeZero, headEventTime - now));

            if (framesThisSegment > 0) {
                mKernel.process(now, framesThisSegment, outputData, frameOffset);

                framesRemaining -= framesThisSegment;
                frameOffset += framesThisSegment;
                now += AUEventSampleTime(framesThisSegment);
            }

            nextEvent = performAllSimultaneousEvents(now, nextEvent);
        }
        mKernel.flushMIDI();
    }

    AURenderEvent const * performAllSimultaneousEvents(AUEventSampleTime now, AURenderEvent const *event) {
        do {
            mKernel.handleOneEvent(now, event);

            event = event->head.next;

        } while (event && event->head.eventSampleTime <= now);
        return event;
    }

    AUInternalRenderBlock internalRenderBlock() {
        return ^AUAudioUnitStatus(AudioUnitRenderActionFlags                 *actionFlags,
                                  const AudioTimeStamp                       *timestamp,
                                  AUAudioFrameCount                           frameCount,
                                  NSInteger                                   outputBusNumber,
                                  AudioBufferList                            *outputData,
                                  const AURenderEvent                        *events,
                                  AURenderPullInputBlock __unsafe_unretained pullInputBlock) {
            (void)actionFlags;
            (void)outputBusNumber;
            (void)pullInputBlock;

            if (frameCount > mKernel.maximumFramesToRender()) {
                return kAudioUnitErr_TooManyFramesToProcess;
            }

            if (outputData) {
                for (UInt32 i = 0; i < outputData->mNumberBuffers; ++i) {
                    if (outputData->mBuffers[i].mData == nullptr) {
                        outputData->mBuffers[i].mData = mKernel.outputBufferPointer(i);
                    }
                }
            }

            processWithEvents(timestamp, frameCount, events, outputData);

            return noErr;
        };

    }
private:
    AutoHarpExtensionDSPKernel& mKernel;
};

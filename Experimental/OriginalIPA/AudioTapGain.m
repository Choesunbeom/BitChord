// BitChord-KR original IPA - post processing tap gain.
// Audio is attenuated AFTER the host app's existing tap processor has completed,
// leaving its EQ, loudness, crossfades and AVAudioSession intact.
// Copyright (c) 2026. Includes BSD-3-Clause fishhook (separate files).
#import <Foundation/Foundation.h>
#import <MediaToolbox/MediaToolbox.h>
#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <stdint.h>
#import <math.h>
#import <string.h>
#import <limits.h>
#import "fishhook.h"

typedef void (*BCHTapProcessFunction)(MTAudioProcessingTapRef, CMItemCount,
    MTAudioProcessingTapFlags, AudioBufferList *, CMItemCount *, MTAudioProcessingTapFlags *);
typedef void (*BCHTapPrepareFunction)(MTAudioProcessingTapRef, CMItemCount,
    const AudioStreamBasicDescription *);
typedef void (*BCHTapFinalizeFunction)(MTAudioProcessingTapRef);

typedef struct BCHTapEntry {
    MTAudioProcessingTapRef tap;
    BCHTapProcessFunction originalProcess;
    BCHTapPrepareFunction originalPrepare;
    BCHTapFinalizeFunction originalFinalize;
    AudioStreamBasicDescription format;
    _Atomic(int) formatReady;
    struct BCHTapEntry *next;
} BCHTapEntry;

static _Atomic(BCHTapEntry *) gFirstTap = NULL;
static _Atomic(float) gPostGain = 1.0f;
static _Atomic(unsigned int) gTapCreated = 0;
static _Atomic(unsigned int) gTapProcessHits = 0;
static _Atomic(unsigned int) gTapApplied = 0;
static OSStatus (*gOriginalTapCreate)(CFAllocatorRef, const MTAudioProcessingTapCallbacks *,
    MTAudioProcessingTapCreationFlags, MTAudioProcessingTapRef *);

static BCHTapEntry *BCHFindTap(MTAudioProcessingTapRef tap) {
    for (BCHTapEntry *entry=atomic_load_explicit(&gFirstTap,memory_order_acquire);
         entry; entry=entry->next) {
        if (entry->tap == tap) return entry;
    }
    return NULL;
}

static void BCHAfterTapProcess(MTAudioProcessingTapRef tap, CMItemCount frames,
    MTAudioProcessingTapFlags flags, AudioBufferList *buffers,
    CMItemCount *framesOut, MTAudioProcessingTapFlags *flagsOut) {
    BCHTapEntry *entry = BCHFindTap(tap);
    if (!entry || !entry->originalProcess) {
        // Never corrupt a processing callback when metadata is unavailable.
        // The UI diagnostic will show tap callbacks were not intercepted.
        if (buffers && framesOut) *framesOut = 0;
        return;
    }

    entry->originalProcess(tap,frames,flags,buffers,framesOut,flagsOut);
    atomic_fetch_add_explicit(&gTapProcessHits,1,memory_order_relaxed);

    float gain=atomic_load_explicit(&gPostGain,memory_order_relaxed);
    if (!buffers || gain>=0.99999f || (framesOut && *framesOut<=0)) return;

    // The callback has ALREADY completed its original output processing.
    // mDataByteSize includes interleaved or planar data as appropriate.
    AudioStreamBasicDescription asbd=entry->format;
    BOOL supported=atomic_load_explicit(&entry->formatReady,memory_order_acquire)
        && asbd.mFormatID==kAudioFormatLinearPCM;
    uint32_t flagsFormat = asbd.mFormatFlags;

    for (UInt32 b=0; b<buffers->mNumberBuffers && b<32; ++b) {
        AudioBuffer *buffer=&buffers->mBuffers[b];
        if (!buffer->mData || buffer->mDataByteSize==0) continue;
        UInt32 byteCount=buffer->mDataByteSize;
        if (gain<0.00001f) {
            // All linear PCM encodings (and also unrecognized encodings)
            // represent digital silence as zeroed output. 
            memset(buffer->mData,0,byteCount);
        } else if (supported && (flagsFormat & kAudioFormatFlagIsFloat)
                   && asbd.mBitsPerChannel==32) {
            float *samples=(float *)buffer->mData;
            UInt32 length=byteCount/sizeof(float);
            for (UInt32 i=0;i<length;i++)samples[i]*=gain;
        } else if (supported && (flagsFormat & kAudioFormatFlagIsFloat)
                   && asbd.mBitsPerChannel==64) {
            double *samples=(double *)buffer->mData;
            UInt32 length=byteCount/sizeof(double);
            for (UInt32 i=0;i<length;i++)samples[i]*=gain;
        } else if (supported && (flagsFormat & kAudioFormatFlagIsSignedInteger)
                   && asbd.mBitsPerChannel==16) {
            int16_t *samples=(int16_t *)buffer->mData;
            UInt32 length=byteCount/sizeof(int16_t);
            for (UInt32 i=0;i<length;i++)samples[i]=(int16_t)lrintf(samples[i]*gain);
        } else if (supported && (flagsFormat & kAudioFormatFlagIsSignedInteger)
                   && asbd.mBitsPerChannel==32) {
            int32_t *samples=(int32_t *)buffer->mData;
            UInt32 length=byteCount/sizeof(int32_t);
            for (UInt32 i=0;i<length;i++)samples[i]=(int32_t)llrint((double)samples[i]*gain);
        }
    }
    atomic_fetch_add_explicit(&gTapApplied,1,memory_order_relaxed);
}

static void BCHTapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames,
                          const AudioStreamBasicDescription *format) {
    BCHTapEntry *entry=BCHFindTap(tap);
    if (!entry) return;
    if (format) {
        entry->format=*format;
        atomic_store_explicit(&entry->formatReady,1,memory_order_release);
    }
    if (entry->originalPrepare) entry->originalPrepare(tap,maxFrames,format);
}
static void BCHTapFinalize(MTAudioProcessingTapRef tap) {
    BCHTapEntry *entry=BCHFindTap(tap);
    if (entry && entry->originalFinalize)entry->originalFinalize(tap);
    // Entry remains in the lock-free list. It is tiny and safe for the lifetime
    // of the app; freeing here could race a rendering callback.
}

static OSStatus BCHTapCreate(CFAllocatorRef allocator,
       const MTAudioProcessingTapCallbacks *callbacks,
       MTAudioProcessingTapCreationFlags flags, MTAudioProcessingTapRef *tapOut) {
    if (!gOriginalTapCreate) return paramErr;
    if (!callbacks || !callbacks->process || !tapOut)
        return gOriginalTapCreate(allocator,callbacks,flags,tapOut);

    BCHTapEntry *entry=(BCHTapEntry *)calloc(1,sizeof(BCHTapEntry));
    if (!entry) return gOriginalTapCreate(allocator,callbacks,flags,tapOut);
    entry->originalProcess=callbacks->process;
    entry->originalPrepare=callbacks->prepare;
    entry->originalFinalize=callbacks->finalize;
    MTAudioProcessingTapCallbacks wrapped=*callbacks;
    wrapped.process=BCHAfterTapProcess;
    wrapped.prepare=BCHTapPrepare;
    wrapped.finalize=BCHTapFinalize;

    OSStatus status=gOriginalTapCreate(allocator,&wrapped,flags,tapOut);
    if (status || !*tapOut) {free(entry);return status;}
    entry->tap=*tapOut;
    BCHTapEntry *old;
    do {
        old=atomic_load_explicit(&gFirstTap,memory_order_acquire);
        entry->next=old;
    } while (!atomic_compare_exchange_weak_explicit(&gFirstTap,&old,entry,
                    memory_order_release,memory_order_relaxed));
    atomic_fetch_add_explicit(&gTapCreated,1,memory_order_relaxed);
    return status;
}

void BCHTapSetGain(float value) {
    if(!isfinite(value))value=1;
    atomic_store_explicit(&gPostGain,fmaxf(0,fminf(1,value)),memory_order_relaxed);
}
void BCHTapGetStats(unsigned int *created,unsigned int *hits,unsigned int *attenuated) {
    if(created)*created=atomic_load_explicit(&gTapCreated,memory_order_relaxed);
    if(hits)*hits=atomic_load_explicit(&gTapProcessHits,memory_order_relaxed);
    if(attenuated)*attenuated=atomic_load_explicit(&gTapApplied,memory_order_relaxed);
}

void BCHTapInstall(void) {
    gOriginalTapCreate = dlsym(RTLD_DEFAULT,"MTAudioProcessingTapCreate");
    if(!gOriginalTapCreate) {
        NSLog(@"[BCHDualVolume] Could not resolve MTAudioProcessingTapCreate");
        return;
    }
    struct rebinding binding = {
        "MTAudioProcessingTapCreate", (void *)BCHTapCreate, NULL
    };
    int result=rebind_symbols(&binding,1);
    NSLog(@"[BCHDualVolume] post-tap hook install=%d",result);
}

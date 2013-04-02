//
//  TMAudioPlayer.m
//  StreamingAudioPlayerFun
//
//  Created by Harper Zhang on 13-4-2.
//  Copyright (c) 2013年 harperzhang. All rights reserved.
//

#import "TMAudioPlayer.h"
#import "TMAudioStreamingOperation.h"
#include <AudioToolbox/AudioToolbox.h>

// Number of audio queue buffers we allocate.
// Needs to be big enough to keep audio pipeline
// busy (non-zero number of queued buffers) but
// not so big that audio takes too long to begin
// (kNumAQBufs * kAQBufSize of data must be
// loaded before playback will start).
//
// Set LOG_QUEUED_BUFFERS to 1 to log how many
// buffers are queued at any time -- if it drops
// to zero too often, this value may need to
// increase. Min 3, typical 8-24.
#define kNumAQBufs 16			

// Number of bytes in each audio queue buffer
// Needs to be big enough to hold a packet of
// audio from the audio file. If number is too
// large, queuing of audio before playback starts
// will take too long.
// Highly compressed files can use smaller
// numbers (512 or less). 2048 should hold all
// but the largest packets. A buffer size error
// will occur if this number is too small.
#define kAQDefaultBufSize 2048	

// Number of packet descriptions in our array
#define kAQMaxPacketDescs 512

@interface TMAudioPlayer () <TMAudioStreamingOperationDelegate>

@end

@implementation TMAudioPlayer
{
    // operation
    NSOperationQueue*   _operationQueue;
    
    // url
    NSURL*              _audioURL;
    
    // Audio stream
    AudioQueueRef                _audioQueue;
    AudioQueueBufferRef          _audioQueueBuffer[kNumAQBufs];
    
	AudioFileStreamID            _audioStream;
    AudioStreamBasicDescription  _audioStremDescription;
    UInt32                       _packetBufferSize;
    BOOL                         _discontinuous;
}

-(id)init
{
    self = [super init];
    if (self)
    {
        _operationQueue = [[NSOperationQueue alloc] init];
        _operationQueue.maxConcurrentOperationCount = 1;
    }
    
    return self;
}

-(void)dealloc
{
    [self cleanupAudioStreamer];
}

#pragma mark - Interface
-(void)playAudioWithURL:(NSURL *)audioURL
{
    NSAssert([[audioURL absoluteString] length] > 0, @"Invalid audio url.");
    if ([[audioURL absoluteString] length] == 0) return;
    
    _audioURL = audioURL;
    
    [self cleanupAudioStreamer];
    
    // queue
    TMAudioStreamingOperation* streamer = [[TMAudioStreamingOperation alloc] initWithURL:audioURL];
    streamer.delegate = self;
    
    [_operationQueue addOperation:streamer];
}

#pragma mark - Internal methods
-(void)cleanupAudioStreamer
{
    for (TMAudioStreamingOperation* operation in _operationQueue.operations)
    {
        operation.delegate = nil;
        [operation cancel];
    }
}

-(void)setupAudioQueue
{
    if (_audioQueue == nil)
    {
        // create queue
        AudioQueueNewOutput(&_audioStremDescription, ASAudioQueueOutputCallback, (__bridge void *)(self), NULL, NULL, 0, &_audioQueue);
        
        // listen the "isRunning" property
        AudioQueueAddPropertyListener(_audioQueue, kAudioQueueProperty_IsRunning, ASAudioQueueIsRunningCallback, (__bridge void *)(self));
        
        // get the packet size if it is available
        UInt32 sizeOfUInt32 = sizeof(UInt32);
        OSStatus err = AudioFileStreamGetProperty(_audioStream, kAudioFileStreamProperty_PacketSizeUpperBound, &sizeOfUInt32, &_packetBufferSize);
        if (err || _packetBufferSize == 0)
        {
            err = AudioFileStreamGetProperty(_audioStream, kAudioFileStreamProperty_MaximumPacketSize, &sizeOfUInt32, &_packetBufferSize);
            if (err || _packetBufferSize == 0)
            {
                // No packet size available, just use the default
                _packetBufferSize = kAQDefaultBufSize;
            }
        }
        
        // allocate audio queue buffers
        for (unsigned int i = 0; i < kNumAQBufs; ++i)
        {
            AudioQueueAllocateBuffer(_audioQueue, _packetBufferSize, &_audioQueueBuffer[i]);
            
        }
    }
}

-(void)setupAudioStreamIfNecessary
{
    if (_audioStream == nil)
    {
        OSErr error = AudioFileStreamOpen((__bridge void *)(self), ASPropertyListenerProc, ASPacketsProc, kAudioFileMP3Type, &_audioStream);
        
        
    }
}

#pragma mark - Audio stream callbacks
static void ASPropertyListenerProc(void* inClientData,
                                   AudioFileStreamID inAudioFileStream,
                                   AudioFileStreamPropertyID inPropertyID,
                                   UInt32* ioFlags)
{
    TMAudioPlayer* player = (__bridge TMAudioPlayer*)inClientData;
    [player handlePropertyChangeForFileStream:inAudioFileStream fileStreamPropertyID:inPropertyID ioFlags:ioFlags];
}

- (void)handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream
                     fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID
                                  ioFlags:(UInt32 *)ioFlags
{
    switch (inPropertyID)
    {
        case kAudioFileStreamProperty_ReadyToProducePackets:
        {
            _discontinuous = YES;
        }
            break;
        case kAudioFileStreamProperty_DataOffset:
        {
        
        }
            break;
        case kAudioFileStreamProperty_AudioDataByteCount:
        {
        
        }
            break;
        case kAudioFileStreamProperty_DataFormat:
        {
            if (_audioStremDescription.mSampleRate == 0)
            {
                UInt32 descriptionSize = sizeof(_audioStremDescription);
                
                // get stream format
                AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &descriptionSize, &_audioStremDescription);
            }
        }
            break;
        case kAudioFileStreamProperty_FormatList:
        {
        
        }
            break;
        default:
            break;
    }
}

static void ASPacketsProc(void* inClientData,
                          UInt32 inNumberBytes,
                          UInt32 inNumberPackets,
                          const void* inInputData,
                          AudioStreamPacketDescription* inPacketDescriptions)
{
    TMAudioPlayer* player = (__bridge TMAudioPlayer*)inClientData;
    [player handleAudioStreamPackets:inInputData numberBytes:inNumberBytes numberPackets:inNumberPackets packetDescriptions:inPacketDescriptions];
}

-(void)handleAudioStreamPackets:(const void*)packets
                    numberBytes:(UInt32)inNumberBytes
                  numberPackets:(UInt32)inNumberPackets
             packetDescriptions:(AudioStreamPacketDescription *)inPacketDescriptions
{
    if (_discontinuous)
    {
        _discontinuous = NO;
    }
    
    if (_audioQueue == nil)
    {
        [self setupAudioQueue];
    }
    
    if (inPacketDescriptions)
    {
    
    }
}

#pragma mark Audio Queue callbacks
static void ASAudioQueueOutputCallback(void* inClientData,
                                       AudioQueueRef inAQ,
                                       AudioQueueBufferRef inBuffer)
{

}

static void ASAudioQueueIsRunningCallback(void *inUserData, AudioQueueRef inAQ, AudioQueuePropertyID inID)
{

}

#pragma mark - TMAudioStreamingOperationDelegate
-(void)audioStreamingOperation:(TMAudioStreamingOperation *)aso didReadBytes:(unsigned char*)bytes length:(long long)length
{
    if (length <= 0) return;
    
    // play
    if (_discontinuous)
    {
        AudioFileStreamParseBytes(_audioStream, length, bytes, kAudioFileStreamParseFlag_Discontinuity);
    }
    else
    {
        AudioFileStreamParseBytes(_audioStream, length, bytes, 0);
    }
}

@end

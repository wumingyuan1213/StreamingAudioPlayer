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

#define BitRateEstimationMaxPackets 5000
#define BitRateEstimationMinPackets 50

@interface TMAudioPlayer () <TMAudioStreamingOperationDelegate>

- (void)handleInterruptionChangeToState:(AudioQueuePropertyID)inInterruptionState;

-(void)handleAudioStreamPackets:(const void*)inInputData
                    numberBytes:(UInt32)inNumberBytes
                  numberPackets:(UInt32)inNumberPackets
             packetDescriptions:(AudioStreamPacketDescription *)inPacketDescriptions;

- (void)handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream
                     fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID
                                  ioFlags:(UInt32 *)ioFlags;

- (void)handleBufferCompleteForQueue:(AudioQueueRef)inAQ
                              buffer:(AudioQueueBufferRef)inBuffer;

- (void)handlePropertyChangeForQueue:(AudioQueueRef)inAQ
                          propertyID:(AudioQueuePropertyID)inID;

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
    
    AudioStreamPacketDescription _packetDescs[kAQMaxPacketDescs];
    
    UInt32                       _packetBufferSize;
    UInt64                       _processedPacketsCount;		// number of packets accumulated for bitrate estimation
	UInt64                       _processedPacketsSizeTotal;	// byte size of accumulated estimation packets
    size_t                       _bytesFilled;
    unsigned int                 _fillBufferIndex;
    size_t                       _packetsFilled;
    NSInteger                    _dataOffset;
    NSInteger _fileLength;		// Length of the file in bytes
	NSInteger _seekByteOffset;	// Seek offset within the file in bytes
	UInt64 _audioDataByteCount;
    
    BOOL                         _discontinuous;
    bool                         _inuse[kNumAQBufs];
    NSInteger                    _buffersUsed;
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
    [self initializeAudioSession];
    
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
        
        // get the cookie size
        UInt32 cookieSize;
        Boolean writable;
        OSStatus ignorableError;
        ignorableError = AudioFileStreamGetPropertyInfo(_audioStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable);
        if (ignorableError)
        {
            return;
        }
        
        // get the cookie data
        void* cookieData = calloc(1, cookieSize);
        ignorableError = AudioFileStreamGetProperty(_audioStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookieData);
        if (ignorableError)
        {
            return;
        }
        
        // set the cookie on the queue.
        ignorableError = AudioQueueSetProperty(_audioQueue, kAudioQueueProperty_MagicCookie, cookieData, cookieSize);
        free(cookieData);
        if (ignorableError)
        {
            return;
        }
    }
}

-(void)setupAudioStream
{
    if (_audioStream == nil)
    {
        AudioFileStreamOpen((__bridge void *)(self), ASPropertyListenerProc, ASPacketsProc, kAudioFileMP3Type, &_audioStream);
        
        
    }
}

-(void)initializeAudioSession
{
    AudioSessionInitialize (
                            NULL,                          // 'NULL' to use the default (main) run loop
                            NULL,                          // 'NULL' to use the default run loop mode
                            ASAudioSessionInterruptionListener,  // a reference to your interruption callback
                            (__bridge void *)(self)                       // data to pass to your interruption listener callback
                            );
    UInt32 sessionCategory = kAudioSessionCategory_MediaPlayback;
    AudioSessionSetProperty (
                             kAudioSessionProperty_AudioCategory,
                             sizeof (sessionCategory),
                             &sessionCategory
                             );
    AudioSessionSetActive(true);
}

#pragma mark - Tools
- (void)enqueueBuffer
{
	@synchronized(self)
	{
//		if ([self isFinishing] || stream == 0)
//		{
//			return;
//		}
		
		_inuse[_fillBufferIndex] = true;		// set in use flag
		_buffersUsed++;
        
		// enqueue buffer
		AudioQueueBufferRef fillBuf = _audioQueueBuffer[_fillBufferIndex];
		fillBuf->mAudioDataByteSize = _bytesFilled;
		
		if (_packetsFilled)
		{
			AudioQueueEnqueueBuffer(_audioQueue, fillBuf, _packetsFilled, _packetDescs);
		}
		else
		{
			AudioQueueEnqueueBuffer(_audioQueue, fillBuf, 0, NULL);
		}
		
//		if (err)
//		{
//			[self failWithErrorCode:AS_AUDIO_QUEUE_ENQUEUE_FAILED];
//			return;
//		}
        
		
//		if (state == AS_BUFFERING ||
//			state == AS_WAITING_FOR_DATA ||
//			state == AS_FLUSHING_EOF ||
//			(state == AS_STOPPED && stopReason == AS_STOPPING_TEMPORARILY))
//		{
//			//
//			// Fill all the buffers before starting. This ensures that the
//			// AudioFileStream stays a small amount ahead of the AudioQueue to
//			// avoid an audio glitch playing streaming files on iPhone SDKs < 3.0
//			//
//			if (state == AS_FLUSHING_EOF || buffersUsed == kNumAQBufs - 1)
//			{
//				if (self.state == AS_BUFFERING)
//				{
//					err = AudioQueueStart(audioQueue, NULL);
//					if (err)
//					{
//						[self failWithErrorCode:AS_AUDIO_QUEUE_START_FAILED];
//						return;
//					}
//					self.state = AS_PLAYING;
//				}
//				else
//				{
//					self.state = AS_WAITING_FOR_QUEUE_TO_START;
//                    
					AudioQueueStart(_audioQueue, NULL);
//					if (err)
//					{
//						[self failWithErrorCode:AS_AUDIO_QUEUE_START_FAILED];
//						return;
//					}
//				}
//			}
//		}
        
		// go to next buffer
		if (++_fillBufferIndex >= kNumAQBufs)
        {
            _fillBufferIndex = 0;
        }
        
		_bytesFilled = 0;		// reset bytes filled
		_packetsFilled = 0;		// reset packets filled
	}
    
	// wait until next buffer is not in use
//	pthread_mutex_lock(&queueBuffersMutex);
//	while (inuse[fillBufferIndex])
//	{
//		pthread_cond_wait(&queueBufferReadyCondition, &queueBuffersMutex);
//	}
//	pthread_mutex_unlock(&queueBuffersMutex);
}

#pragma mark - Audio stream callbacks
static void ASAudioSessionInterruptionListener(void *inClientData, UInt32 inInterruptionState)
{
	TMAudioPlayer* player = (__bridge TMAudioPlayer *)inClientData;
	[player handleInterruptionChangeToState:inInterruptionState];
}

- (void)handleInterruptionChangeToState:(AudioQueuePropertyID)inInterruptionState
{
	if (inInterruptionState == kAudioSessionBeginInterruption)
	{
//		if ([self isPlaying]) {
//			[self pause];
//			
//			pausedByInterruption = YES;
//		}
	}
	else if (inInterruptionState == kAudioSessionEndInterruption)
	{
		AudioSessionSetActive( true );
		
//		if ([self isPaused] && pausedByInterruption) {
//			[self pause]; // this is actually resume
//			
//			pausedByInterruption = NO; // this is redundant
//		}
	}
}

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
            SInt64 offset;
			UInt32 offsetSize = sizeof(offset);
			AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataOffset, &offsetSize, &offset);
//			if (err)
//			{
//				[self failWithErrorCode:AS_FILE_STREAM_GET_PROPERTY_FAILED];
//				return;
//			}
			_dataOffset = offset;
			
			if (_audioDataByteCount)
			{
				_fileLength = _dataOffset + _audioDataByteCount;
			}
        }
            break;
        case kAudioFileStreamProperty_AudioDataByteCount:
        {
            UInt32 byteCountSize = sizeof(UInt64);
			AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_AudioDataByteCount, &byteCountSize, &_audioDataByteCount);
//			if (err)
//			{
//				[self failWithErrorCode:AS_FILE_STREAM_GET_PROPERTY_FAILED];
//				return;
//			}
			_fileLength = _dataOffset + _audioDataByteCount;
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
            Boolean outWriteable;
			UInt32 formatListSize;
			AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, &outWriteable);
//			if (err)
//			{
//				[self failWithErrorCode:AS_FILE_STREAM_GET_PROPERTY_FAILED];
//				return;
//			}
			
			AudioFormatListItem *formatList = malloc(formatListSize);
	        AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, formatList);
//			if (err)
//			{
//				free(formatList);
//				[self failWithErrorCode:AS_FILE_STREAM_GET_PROPERTY_FAILED];
//				return;
//			}
            
			for (int i = 0; i * sizeof(AudioFormatListItem) < formatListSize; i += sizeof(AudioFormatListItem))
			{
				AudioStreamBasicDescription pasbd = formatList[i].mASBD;
                
				if (pasbd.mFormatID == kAudioFormatMPEG4AAC_HE ||
					pasbd.mFormatID == kAudioFormatMPEG4AAC_HE_V2)
				{
					//
					// We've found HE-AAC, remember this to tell the audio queue
					// when we construct it.
					//
#if !TARGET_IPHONE_SIMULATOR
					_audioStremDescription = pasbd;
#endif
					break;
				}
			}
			free(formatList);
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

-(void)handleAudioStreamPackets:(const void*)inInputData
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
        for (int i = 0; i < inNumberPackets; ++i)
		{
			SInt64 packetOffset = inPacketDescriptions[i].mStartOffset;
			SInt64 packetSize   = inPacketDescriptions[i].mDataByteSize;
			size_t bufSpaceRemaining;
			
			if (_processedPacketsCount < BitRateEstimationMaxPackets)
			{
				_processedPacketsSizeTotal += packetSize;
				_processedPacketsCount += 1;
			}
			
			@synchronized(self)
			{
				// If the audio was terminated before this point, then
				// exit.
//				if ([self isFinishing])
//				{
//					return;
//				}
				
				if (packetSize > _packetBufferSize)
				{
//					[self failWithErrorCode:AS_AUDIO_BUFFER_TOO_SMALL];
				}
                
				bufSpaceRemaining = _packetBufferSize - _bytesFilled;
			}
            
			// if the space remaining in the buffer is not enough for this packet, then enqueue the buffer.
			if (bufSpaceRemaining < packetSize)
			{
				[self enqueueBuffer];
			}
			
			@synchronized(self)
			{
				// If the audio was terminated while waiting for a buffer, then
				// exit.
//				if ([self isFinishing])
//				{
//					return;
//				}
				
				//
				// If there was some kind of issue with enqueueBuffer and we didn't
				// make space for the new audio data then back out
				//
				if (_bytesFilled + packetSize > _packetBufferSize)
				{
					return;
				}
				
				// copy data to the audio queue buffer
				AudioQueueBufferRef fillBuf = _audioQueueBuffer[_fillBufferIndex];
				memcpy((char*)fillBuf->mAudioData + _bytesFilled, (const char*)inInputData + packetOffset, packetSize);
                
				// fill out packet description
				_packetDescs[_packetsFilled] = inPacketDescriptions[i];
				_packetDescs[_packetsFilled].mStartOffset = _bytesFilled;
				// keep track of bytes filled and packets filled
				_bytesFilled += packetSize;
				_packetsFilled += 1;
			}
			
			// if that was the last free packet description, then enqueue the buffer.
			size_t packetsDescsRemaining = kAQMaxPacketDescs - _packetsFilled;
			if (packetsDescsRemaining == 0)
            {
				[self enqueueBuffer];
			}
		}
    }
    else
    {
        size_t offset = 0;
		while (inNumberBytes)
		{
			// if the space remaining in the buffer is not enough for this packet, then enqueue the buffer.
			size_t bufSpaceRemaining = kAQDefaultBufSize - _bytesFilled;
			if (bufSpaceRemaining < inNumberBytes)
			{
				[self enqueueBuffer];
			}
			
			@synchronized(self)
			{
				// If the audio was terminated while waiting for a buffer, then
				// exit.
//				if ([self isFinishing])
//				{
//					return;
//				}
				
				bufSpaceRemaining = kAQDefaultBufSize - _bytesFilled;
				size_t copySize;
				if (bufSpaceRemaining < inNumberBytes)
				{
					copySize = bufSpaceRemaining;
				}
				else
				{
					copySize = inNumberBytes;
				}
                
				//
				// If there was some kind of issue with enqueueBuffer and we didn't
				// make space for the new audio data then back out
				//
				if (_bytesFilled > _packetBufferSize)
				{
					return;
				}
				
				// copy data to the audio queue buffer
				AudioQueueBufferRef fillBuf = _audioQueueBuffer[_fillBufferIndex];
				memcpy((char*)fillBuf->mAudioData + _bytesFilled, (const char*)(inInputData + offset), copySize);
                
				// keep track of bytes filled and packets filled
				_bytesFilled += copySize;
				_packetsFilled = 0;
				inNumberBytes -= copySize;
				offset += copySize;
			}
		}
    }
}

#pragma mark Audio Queue callbacks
static void ASAudioQueueOutputCallback(void* inClientData,
                                       AudioQueueRef inAQ,
                                       AudioQueueBufferRef inBuffer)
{
    TMAudioPlayer* player = (__bridge TMAudioPlayer*)inClientData;
	[player handleBufferCompleteForQueue:inAQ buffer:inBuffer];
}

- (void)handleBufferCompleteForQueue:(AudioQueueRef)inAQ buffer:(AudioQueueBufferRef)inBuffer
{
    unsigned int bufIndex = -1;
	for (unsigned int i = 0; i < kNumAQBufs; ++i)
	{
		if (inBuffer == _audioQueueBuffer[i])
		{
			bufIndex = i;
			break;
		}
	}
	
	if (bufIndex == -1)
	{
//		[self failWithErrorCode:AS_AUDIO_QUEUE_BUFFER_MISMATCH];
//		pthread_mutex_lock(&queueBuffersMutex);
//		pthread_cond_signal(&queueBufferReadyCondition);
//		pthread_mutex_unlock(&queueBuffersMutex);
		return;
	}

	// signal waiting thread that the buffer is free.
//	pthread_mutex_lock(&queueBuffersMutex);
	_inuse[bufIndex] = false;
	_buffersUsed--;
}

static void ASAudioQueueIsRunningCallback(void *inUserData, AudioQueueRef inAQ, AudioQueuePropertyID inID)
{
    TMAudioPlayer* player = (__bridge TMAudioPlayer*)inUserData;
    [player handlePropertyChangeForQueue:inAQ propertyID:inID];
}

- (void)handlePropertyChangeForQueue:(AudioQueueRef)inAQ
                          propertyID:(AudioQueuePropertyID)inID
{

}

#pragma mark - TMAudioStreamingOperationDelegate
-(void)audioStreamingOperation:(TMAudioStreamingOperation *)aso didReadBytes:(unsigned char*)bytes length:(long long)length
{
    if (length <= 0) return;
    
    [self setupAudioQueue];
    [self setupAudioStream];
    
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

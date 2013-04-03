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
#include <pthread.h>

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

#define BitRateEstimationMinPackets 50

enum {
    TMAudioPlayerStatusIdle = 0,
    TMAudioPlayerStatusBuffering,
    TMAudioPlayerStatusPlaying,
    TMAudioPlayerStatusPaused
};
typedef NSUInteger TMAudioPlayerStatus;

@interface TMAudioPlayer () <TMAudioStreamingOperationDelegate>

@end

@implementation TMAudioPlayer
{
    // operation
    NSOperationQueue*            _operationQueue;
    
    // url
    NSURL*                       _audioURL;
    
    // Audio Queue
    AudioQueueRef                _audioQueue; // 音频数据管理队列
    
    // Audio stream
	AudioFileStreamID            _audioStream; // 音频流句柄
    AudioStreamBasicDescription  _audioStremDescription; // 音频的一些属性描述
    
    // packet相关
    AudioStreamPacketDescription _packetDescs[kAQMaxPacketDescs]; // 数据包信息数组
    size_t                       _packetsFilled; // enqueue之前记录包的数量，每次enqueue完后清零
    
    // buffer相关变量
    AudioQueueBufferRef          _audioQueueBuffer[kNumAQBufs]; // 音频队列中的buffer数组，buffer被作为一个循环队列填充/使用(播放)数据
    UInt32                       _packetBufferSize;
    size_t                       _bytesFilled;
    unsigned int                 _fillBufferIndex; // 当前正在填充的buffer索引
    pthread_mutex_t              _queueBuffersMutex; // 保护正在使用中buffer的互斥锁
	pthread_cond_t               _queueBufferReadyCondition; // 条件变量，用于等待buffer状态变为可用
    bool                         _inuse[kNumAQBufs]; // 每个buffer的状态记录数组
    NSInteger                    _buffersUsed; // 使用中的buffer个数
    
    BOOL                         _discontinuous;
    TMAudioPlayerStatus          _status;
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
    [self cleanupAudioStream];
}

#pragma mark - Interface
-(void)playAudioWithURL:(NSURL *)audioURL
{
    NSAssert([[audioURL absoluteString] length] > 0, @"Invalid audio url.");
    if ([[audioURL absoluteString] length] == 0) return;
    
    _audioURL = audioURL;
    
    // 0. cleanup audio stream
    [self cleanupAudioStream];
    
    // 1. initialize audio session
    [self initializeAudioSession];
    
    // 2. start audio downloading
    TMAudioStreamingOperation* streamOperation = [[TMAudioStreamingOperation alloc] initWithURL:audioURL];
    streamOperation.delegate = self;
    
    [_operationQueue addOperation:streamOperation];
    
    // 3. create audio stream and queue in the streamer call back function
}

-(void)stop
{
    [self cleanupAudioStream];
    
    [self.delegate audioPlayerDidChangeStatus:self];
}

-(void)pause
{
    @synchronized(self)
    {
        _status = TMAudioPlayerStatusPaused;
        AudioQueuePause(_audioQueue);
        
        [self.delegate audioPlayerDidChangeStatus:self];
    }
}

-(void)resume
{
    @synchronized(self)
    {
        _status = TMAudioPlayerStatusPlaying;
        AudioSessionSetActive(true);
        AudioQueueStart(_audioQueue, NULL);
        
        [self.delegate audioPlayerDidChangeStatus:self];
    }
}

-(BOOL)isPlaying
{
    return (_status == TMAudioPlayerStatusPlaying);
}

-(BOOL)isPaused
{
    return (_status == TMAudioPlayerStatusPaused);
}

#pragma mark - Internal methods
-(void)cleanupAudioStream
{
    @synchronized(self)
    {
        for (TMAudioStreamingOperation* operation in _operationQueue.operations)
        {
            operation.delegate = nil;
            [operation cancel];
        }
        
        // cleanup audio queue
        if (_audioStream)
        {
            AudioFileStreamClose(_audioStream);
            _audioStream = nil;
        }
        
        // cleanup audio queue
        if (_audioQueue)
        {
            AudioQueueDispose(_audioQueue, true);
            _audioQueue = nil;
        }
        
        // 释放锁
        pthread_mutex_destroy(&_queueBuffersMutex);
        pthread_cond_destroy(&_queueBufferReadyCondition);
        
        // cleanup audio session
        AudioSessionSetActive(false);
        
        // reset iVars
        _status = TMAudioPlayerStatusIdle;
    }
}

-(void)initializeAudioSession
{
    AudioSessionInitialize(NULL,                          // 'NULL' to use the default (main) run loop
                            NULL,                          // 'NULL' to use the default run loop mode
                            tm_AudioSessionInterruptionListener, (__bridge void *)(self));
    
    UInt32 sessionCategory = kAudioSessionCategory_MediaPlayback;
    AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(sessionCategory), &sessionCategory);
    
    AudioSessionSetActive(true);
    
    // initialize a mutex and condition so that we can block on buffers in use.
    pthread_mutex_init(&_queueBuffersMutex, NULL);
    pthread_cond_init(&_queueBufferReadyCondition, NULL);
}

-(void)setupAudioQueue
{
    if (_audioQueue == nil)
    {
        // create queue
        AudioQueueNewOutput(&_audioStremDescription, tm_AudioQueueOutputCallback, (__bridge void *)(self), NULL, NULL, 0, &_audioQueue);
        
        // listening the "isRunning" property
        AudioQueueAddPropertyListener(_audioQueue, kAudioQueueProperty_IsRunning, tm_AudioQueueIsRunningCallback, (__bridge void *)(self));
        
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
        AudioFileStreamOpen((__bridge void *)(self), tm_AudioStreamPropertyListenerProc, tm_AudioStreamPacketsProc, kAudioFileMP3Type, &_audioStream);
        
        
    }
}

#pragma mark - Enqueue Buffer
- (void)enqueueBuffer
{
	@synchronized(self)
	{
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
        
        // start queue
        if (_status != TMAudioPlayerStatusPaused)
        {
            AudioQueueStart(_audioQueue, NULL);
        }
        
		// go to next buffer
		if (++_fillBufferIndex >= kNumAQBufs)
        {
            _fillBufferIndex = 0;
        }
        
		_bytesFilled = 0;		// reset bytes filled
		_packetsFilled = 0;		// reset packets filled
	}
    
	// wait until next buffer is not in use
	pthread_mutex_lock(&_queueBuffersMutex);
	while (_inuse[_fillBufferIndex])
	{
		pthread_cond_wait(&_queueBufferReadyCondition, &_queueBuffersMutex);
	}
	pthread_mutex_unlock(&_queueBuffersMutex);
}

#pragma mark - Audio Session Callbacks
static void tm_AudioSessionInterruptionListener(void *inClientData, UInt32 inInterruptionState)
{
	TMAudioPlayer* player = (__bridge TMAudioPlayer *)inClientData;
	[player handleInterruptionChangeToState:inInterruptionState];
}

- (void)handleInterruptionChangeToState:(AudioQueuePropertyID)inInterruptionState
{
    @synchronized(self)
    {
        if (inInterruptionState == kAudioSessionBeginInterruption)
        {
            [self pause];
        }
        else if (inInterruptionState == kAudioSessionEndInterruption)
        {
            [self resume];
        }
    }
}

#pragma mark - Audio Stream Callbacks
static void tm_AudioStreamPropertyListenerProc(void* inClientData,
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
    @synchronized(self)
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
            Boolean outWriteable;
			UInt32 formatListSize;
			AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, &outWriteable);
			
			AudioFormatListItem *formatList = malloc(formatListSize);
	        AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, formatList);
            
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
					_audioStremDescription = pasbd;
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
}

static void tm_AudioStreamPacketsProc(void* inClientData,
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

#pragma mark Audio Queue Callbacks
static void tm_AudioQueueOutputCallback(void* inClientData,
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
		pthread_mutex_lock(&_queueBuffersMutex);
		pthread_cond_signal(&_queueBufferReadyCondition);
		pthread_mutex_unlock(&_queueBuffersMutex);
		return;
	}

	// signal waiting thread that the buffer is free.
	pthread_mutex_lock(&_queueBuffersMutex);
	_inuse[bufIndex] = false;
	_buffersUsed--;
    
    pthread_cond_signal(&_queueBufferReadyCondition);
	pthread_mutex_unlock(&_queueBuffersMutex);
}

static void tm_AudioQueueIsRunningCallback(void *inUserData, AudioQueueRef inAQ, AudioQueuePropertyID inID)
{
    TMAudioPlayer* player = (__bridge TMAudioPlayer*)inUserData;
    [player handleQueuePropertyChangeForQueue:inAQ propertyID:inID];
}

- (void)handleQueuePropertyChangeForQueue:(AudioQueueRef)inAQ
                               propertyID:(AudioQueuePropertyID)inID
{

}

#pragma mark - TMAudioStreamingOperationDelegate
-(BOOL)shouldAudioStreamingOperationContinueReading:(TMAudioStreamingOperation *)aso
{
    return (_status != TMAudioPlayerStatusPaused);
}

-(void)audioStreamingOperation:(TMAudioStreamingOperation *)aso didReadBytes:(unsigned char*)bytes length:(long long)length
{
    if (length <= 0) return;
    
    @synchronized(self)
    {
        // setup audio stream if necessary
        [self setupAudioStream];
        
        //解析字节流，解析完成的数据将调用AudioFileStream_PacketsProc回调
        if (_discontinuous)
        {
            AudioFileStreamParseBytes(_audioStream, length, bytes, kAudioFileStreamParseFlag_Discontinuity);
        }
        else
        {
            AudioFileStreamParseBytes(_audioStream, length, bytes, 0);
        }
    }
}

-(void)audioStreamingOperation:(TMAudioStreamingOperation *)aso failedWithError:(long)errorCode
{
    [self stop];
}

@end

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
// buffer太小，会导致收到的数据包都比buffer大，无法将数据拷贝进去
#define kAQDefaultBufSize 2048	

// Number of packet descriptions in our array
#define kAQMaxPacketDescs 512

enum {
    TMAudioPlayerStatusIdle = 0,
    TMAudioPlayerStatusBuffering,
    TMAudioPlayerStatusPlaying,
    TMAudioPlayerStatusPaused
};
typedef NSUInteger TMAudioPlayerStatus;

@interface TMAudioPlayer () <TMAudioStreamingOperationDelegate>

// audio session
- (void)handleInterruptionChangeToState:(AudioQueuePropertyID)inInterruptionState;
-(void)handleAudioSessionPropertyChangeInProperty:(AudioSessionPropertyID)inID
                                       inDataSize:(UInt32)inDataSize
                                           inData:(const void *)inData;

// audio stream
- (void)handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream
                     fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID
                                  ioFlags:(UInt32 *)ioFlags;
-(void)handleAudioStreamPackets:(const void*)inInputData
                    numberBytes:(UInt32)inNumberBytes
                  numberPackets:(UInt32)inNumberPackets
             packetDescriptions:(AudioStreamPacketDescription *)inPacketDescriptions;

// audio queue
- (void)handleBufferCompleteForQueue:(AudioQueueRef)inAQ buffer:(AudioQueueBufferRef)inBuffer;
- (void)handleQueuePropertyChangeForQueue:(AudioQueueRef)inAQ
                               propertyID:(AudioQueuePropertyID)inID;

@end

@implementation TMAudioPlayer
{
    // operation
    NSOperationQueue*            _operationQueue; // 执行数据流式下载的queue
    
    // url
    NSURL*                       _audioURL;
    
    // Audio Queue
    AudioQueueRef                _audioQueue; // 音频数据管理队列
    
    // Audio stream
	AudioFileStreamID            _audioStream; // 音频流句柄
    AudioStreamBasicDescription  _audioStremDescription; // 音频的一些属性描述
    
    // buffer相关变量
    AudioQueueBufferRef          _audioQueueBuffer[kNumAQBufs]; // 音频队列中的buffer数组，buffer被作为一个循环队列填充/使用(播放)数据
    bool                         _inuse[kNumAQBufs]; // 每个buffer的状态记录数组
    NSInteger                    _buffersUsed; // 使用中的buffer个数
    
    pthread_mutex_t              _queueBuffersMutex; // 保护正在使用中buffer的互斥锁
	pthread_cond_t               _queueBufferReadyCondition; // 条件变量，用于等待buffer状态变为可用
        
    BOOL                         _audioSessionInitialized; // 已初始化session，重复初始化会报错
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
    
    // update status
    _status = TMAudioPlayerStatusPlaying;
}

-(void)stop
{
    @synchronized(self)
    {
        [self cleanupAudioStream];
        
        [self.delegate audioPlayerDidChangeStatus:self];
    }
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
        if (AudioSessionSetActive(true))
        {
            // set active error
            [self failedWithErrorCode:1];
            return;
        }
        
        if (AudioQueueStart(_audioQueue, NULL))
        {
            // start audio queue error
            [self failedWithErrorCode:1];
            return;
        }
        
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
    if (!_audioSessionInitialized)
    {
        if (AudioSessionInitialize(NULL,  NULL, tm_AudioSessionInterruptionListener, (__bridge void *)(self)))
        {
            // audio session initialize error
            [self failedWithErrorCode:1];
            return;
        }
        
        UInt32 sessionCategory = kAudioSessionCategory_MediaPlayback;
        AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(sessionCategory), &sessionCategory);
        
        // route change(如:耳机插拔)
        AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, tm_AudioSessionPropertyListener, (__bridge void *)(self));
    }
    
    if (AudioSessionSetActive(true))
    {
        // set active error
        [self failedWithErrorCode:1];
        return;
    }
    
    // initialize a mutex and condition so that we can block on buffers in use.
    pthread_mutex_init(&_queueBuffersMutex, NULL);
    pthread_cond_init(&_queueBufferReadyCondition, NULL);
}

-(void)setupAudioQueue
{
    if (_audioQueue == nil)
    {
        // create queue
        if (AudioQueueNewOutput(&_audioStremDescription, tm_AudioQueueOutputCallback, (__bridge void *)(self), NULL, NULL, 0, &_audioQueue))
        {
            [self failedWithErrorCode:1];
            return;
        }
        
        // listening the "isRunning" property
        AudioQueueAddPropertyListener(_audioQueue, kAudioQueueProperty_IsRunning, tm_AudioQueueIsRunningCallback, (__bridge void *)(self));
        
        // allocate audio queue buffers
        for (unsigned int i = 0; i < kNumAQBufs; ++i)
        {
            if (AudioQueueAllocateBuffer(_audioQueue, kAQDefaultBufSize, &_audioQueueBuffer[i]))
            {
                // alloc queue error
                [self failedWithErrorCode:1];
                return;
            }
        }
    }
}

-(void)setupAudioStream
{
    if (_audioStream == nil)
    {
        if(AudioFileStreamOpen((__bridge void *)(self), tm_AudioStreamPropertyListenerProc, tm_AudioStreamPacketsProc, kAudioFileMP3Type, &_audioStream))
        {
            // open audio file stream error
            [self failedWithErrorCode:1];
        }
    }
}

-(void)failedWithErrorCode:(NSInteger)errorCode
{
    [self cleanupAudioStream];
    [self.delegate audioPlayer:self failedWithError:[NSError errorWithDomain:@"com.tencent" code:errorCode userInfo:nil]];
}

#pragma mark - Enqueue Buffer
- (void)enqueueBuffer
{
}

-(void)enqueueBufferAtIndex:(NSUInteger)index
        numberOfFilledBytes:(NSUInteger)numberOfFilledBytes
      numberOfFilledPackets:(NSUInteger)numberOfFilledPackets
         packetDescriptions:(AudioStreamPacketDescription[])packetDescriptions
{
	@synchronized(self)
	{
		_inuse[index] = true;		// set in use flag
		_buffersUsed++;
        
		// enqueue buffer
		AudioQueueBufferRef fillBuf = _audioQueueBuffer[index];
		fillBuf->mAudioDataByteSize = numberOfFilledBytes;
		
		if (numberOfFilledPackets > 0)
		{
			AudioQueueEnqueueBuffer(_audioQueue, fillBuf, numberOfFilledPackets, packetDescriptions);
		}
		else
		{
            AudioQueueEnqueueBuffer(_audioQueue, fillBuf, 0, NULL);
		}
        
        // start queue
        if (_status != TMAudioPlayerStatusPaused)
        {
            if (AudioQueueStart(_audioQueue, NULL))
            {
                [self failedWithErrorCode:1];
                return;
            }
        }
        
		// go to next buffer
		if (++index >= kNumAQBufs)
        {
            index = 0;
        }
	}
    
	// wait until next buffer is not in use
	pthread_mutex_lock(&_queueBuffersMutex);
	while (_inuse[index])
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

static void tm_AudioSessionPropertyListener(void* inClientData, AudioSessionPropertyID inID, UInt32 inDataSize, const void* inData)
{
    TMAudioPlayer* player = (__bridge TMAudioPlayer *)inClientData;
    [player handleAudioSessionPropertyChangeInProperty:inID inDataSize:inDataSize inData:inData];
}

-(void)handleAudioSessionPropertyChangeInProperty:(AudioSessionPropertyID)inID
                                       inDataSize:(UInt32)inDataSize
                                           inData:(const void *)inData
{
    if (inID == kAudioSessionProperty_AudioRouteChange)
    {
        CFDictionaryRef routeChangeDictionary = inData;
        CFNumberRef routeChangeReasonRef = CFDictionaryGetValue (routeChangeDictionary, CFSTR(kAudioSession_AudioRouteChangeKey_Reason));
        SInt32 routeChangeReason;
        CFNumberGetValue(routeChangeReasonRef, kCFNumberSInt32Type, &routeChangeReason);
        
        if (routeChangeReason == kAudioSessionRouteChangeReason_OldDeviceUnavailable
            || routeChangeReason == kAudioSessionRouteChangeReason_NewDeviceAvailable)
        {
            CFStringRef route;
            UInt32 propertySize = sizeof(CFStringRef);
            if (AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &propertySize, &route) == 0)
            {
                NSString *routeString = (__bridge NSString *) route;
                if ([routeString isEqualToString: @"Headphone"] == NO)
                {
                    // 拔出耳机
                    [self pause];
                }
            }
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
    
    // setup audio queue if necessary
    if (_audioQueue == nil)
    {
        [self setupAudioQueue];
    }
    
    static NSUInteger fillingBufferIndex = 0;
    static size_t bytesFilled = 0; // 这个包已被添加到buffer里的字节数
    
    // 如果有描述信息，表示使用的是VBR(动态比特率)，否则是CBR(固定比特率)
    if (inPacketDescriptions)
    {
        static size_t packetsFilled = 0; // 已被添加到buffer的包数
        AudioStreamPacketDescription packetDescs[kAQMaxPacketDescs];
        
        for (int i = 0; i < inNumberPackets; ++i)
		{
			SInt64 packetOffset = inPacketDescriptions[i].mStartOffset;
			SInt64 packetSize   = inPacketDescriptions[i].mDataByteSize;
			size_t bufSpaceRemaining = kAQDefaultBufSize - bytesFilled;
            
			// 当前buffer已经不能包含完整个包，就入队(enqueue)，将该包放入下一个buffer
            // 否则，继续将包拷贝到当前buffer中
			if (bufSpaceRemaining < packetSize)
			{
                [self enqueueBufferAtIndex:fillingBufferIndex
                       numberOfFilledBytes:bytesFilled
                     numberOfFilledPackets:packetsFilled
                        packetDescriptions:packetDescs];
                
                // 向下一个buffer填充数据
                // TODO: 如果下一个buffer还没有播放完，如何处理呢？应该让readStream停止
                ++fillingBufferIndex;
                
                if (fillingBufferIndex >= kNumAQBufs)
                {
                    // 回到第一个buffer
                    fillingBufferIndex = 0;
                }
                
                bytesFilled = 0;
                packetsFilled = 0;
			}
			
			@synchronized(self)
			{
				//
				// If there was some kind of issue with enqueueBuffer and we didn't
				// make space for the new audio data then back out
				//
				if (bytesFilled + packetSize > kAQDefaultBufSize)
				{
					return;
				}
				
				// 当前包放入当前buffer
				AudioQueueBufferRef fillBuf = _audioQueueBuffer[fillingBufferIndex];
				memcpy((char*)fillBuf->mAudioData + bytesFilled, (const char*)inInputData + packetOffset, packetSize);
                
				// fill out packet description
				packetDescs[packetsFilled] = inPacketDescriptions[i];
				packetDescs[packetsFilled].mStartOffset = bytesFilled;
                
				// keep track of bytes filled and packets filled
				bytesFilled += packetSize;
				packetsFilled += 1;
			}
			
			// if that was the last free packet description, then enqueue the buffer.
			size_t packetsDescsRemaining = kAQMaxPacketDescs - packetsFilled;
			if (packetsDescsRemaining == 0)
            {
                [self enqueueBufferAtIndex:fillingBufferIndex
                       numberOfFilledBytes:bytesFilled
                     numberOfFilledPackets:packetsFilled
                        packetDescriptions:packetDescs];
                
                ++fillingBufferIndex;
                
                if (fillingBufferIndex >= kNumAQBufs)
                {
                    // 回到第一个buffer
                    fillingBufferIndex = 0;
                }
                
                bytesFilled = 0;
                packetsFilled = 0;
			}
		}
    }
    else
    {
        size_t offset = 0;
		while (inNumberBytes > 0)
		{
			// 如果当前buffer没有足够空间，则将buffer放入queue队列，然后填充下一个buffer
			size_t bufSpaceRemaining = kAQDefaultBufSize - bytesFilled;
			if (bufSpaceRemaining < inNumberBytes)
			{
                [self enqueueBufferAtIndex:fillingBufferIndex
                       numberOfFilledBytes:bytesFilled
                     numberOfFilledPackets:0
                        packetDescriptions:NULL];
                
                // 下一个buffer
                ++fillingBufferIndex;
                
                if (fillingBufferIndex >= kNumAQBufs)
                {
                    // 回到第一个buffer
                    fillingBufferIndex = 0;
                }
                
                bytesFilled = 0;
			}
			
			@synchronized(self)
			{
				bufSpaceRemaining = kAQDefaultBufSize - bytesFilled;
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
				if (bytesFilled > kAQDefaultBufSize)
				{
					return;
				}
				
				// copy data to the audio queue buffer
				AudioQueueBufferRef fillBuf = _audioQueueBuffer[fillingBufferIndex];
				memcpy((char*)fillBuf->mAudioData + bytesFilled, (const char*)(inInputData + offset), copySize);
                
				bytesFilled += copySize;
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
    //kAudioQueueProperty_IsRunning
//    if (inID == kAudioQueueProperty_IsRunning)
//    {
//        UInt32 isRunning;
//        UInt32 ioDataSize = sizeof(isRunning);
//        AudioQueueGetProperty(inAQ, kAudioQueueProperty_IsRunning, &isRunning, &ioDataSize);
//        if (isRunning > 0)
//        {
//            // running
//            NSLog(@"audio queue is running.");
//        }
//        else
//        {
//            // not running
//            NSLog(@"audio queue not running.");
////            [self stop];
//        }
//    }
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

-(void)audioStreamingOperation:(TMAudioStreamingOperation *)aso failedWithError:(NSError*)error
{
    [self failedWithErrorCode:1];
}

-(void)audioStreamingOperationDidFinish:(TMAudioStreamingOperation *)aso
{
    [self stop];
}

@end

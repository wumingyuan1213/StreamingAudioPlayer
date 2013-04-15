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
// (kAQNumberOfBuffer * kAQDefaultBufSize of data must be
// loaded before playback will start).
//
// Set LOG_QUEUED_BUFFERS to 1 to log how many
// buffers are queued at any time -- if it drops
// to zero too often, this value may need to
// increase. Min 3, typical 8-24.
#define kAQNumberOfBuffer 16 //16

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
#define kAQMaxPacketDescriptions 512

enum {
    TMAudioPlayerStatusIdle = 0,
    TMAudioPlayerStatusPlaying,
    TMAudioPlayerStatusPaused,
    TMAudioPlayerStatusFinishing  // 正在结束中
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
    BOOL                         _audioStreamingFinished; // 音频下载是否已经结束
    
    // url
    NSURL*                       _audioURL;
    
    // Audio Queue
    AudioQueueRef                _audioQueue; // 音频数据管理队列
    
    // Audio stream
	AudioFileStreamID            _audioStream; // 音频流句柄
    AudioStreamBasicDescription  _audioStremDescription; // 音频的一些属性描述
    
    // buffer相关变量
    AudioQueueBufferRef          _audioQueueBuffers[kAQNumberOfBuffer]; // 音频队列中的buffer数组，buffer被作为一个循环队列填充/使用(播放)数据
    bool                         _bufferInuseFlags[kAQNumberOfBuffer]; // 每个buffer的状态记录数组
    AudioStreamPacketDescription _packetDescriptions[kAQMaxPacketDescriptions];
    unsigned int                 _fillingBufferIndex;
    NSInteger                    _buffersUsed; // 使用中的buffer个数
    size_t                       _numberOfFilledBytes;
    size_t                       _numberOfFilledPackets;
    
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
-(BOOL)playAudioWithURL:(NSURL *)audioURL
{
    NSAssert([[audioURL absoluteString] length] > 0, @"Invalid audio url.");
    if ([[audioURL absoluteString] length] == 0) return NO;
    
    _audioURL = audioURL;
    
    // 0. cleanup audio stream
    [self cleanupAudioStream];
    
    // 1. initialize audio session
    [self initializeAudioSession];
    
    // 2. start audio downloading
    _audioStreamingFinished = NO;
    TMAudioStreamingOperation* streamOperation = [[TMAudioStreamingOperation alloc] initWithURL:audioURL];
    streamOperation.delegate = self;
    
    [_operationQueue addOperation:streamOperation];
    
    // 3. create audio stream and queue in the streamer call back function
    
    // update status
    _status = TMAudioPlayerStatusPlaying;
    
    return YES;
}

-(void)stop
{
    // 立即调用此方法，以防止queue的回调造成线程死锁
    AudioQueueStop(_audioQueue, true);
    
    [self cleanupAudioStream];

    [self.delegate audioPlayerDidChangeStatus:self];
}

-(void)pause
{
    AudioQueuePause(_audioQueue);
    
    _status = TMAudioPlayerStatusPaused;
}

-(void)resume
{
    OSStatus error = AudioSessionSetActive(true);
    if (error)
    {
        // set active error
        [self failedWithErrorCode:error];
    }
    
    error = AudioQueueStart(_audioQueue, NULL);
    if (error)
    {
        // start audio queue error
        [self failedWithErrorCode:error];
    }
    
    _status = TMAudioPlayerStatusPlaying;
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
    if ([self isAudioQueueRunning])
    {
        // 立即停止，使所有queue相关回调不再触发
        AudioQueueStop(_audioQueue, YES);
    }
    
    // 释放锁
    pthread_mutex_destroy(&_queueBuffersMutex);
    pthread_cond_destroy(&_queueBufferReadyCondition);
    
    @synchronized(self)
    {
        _status = TMAudioPlayerStatusFinishing;
        
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
            
            _fillingBufferIndex = 0;
            _buffersUsed = 0;
            _numberOfFilledBytes = 0;
            _numberOfFilledPackets = 0;
            
            for (int i = 0; i != kAQNumberOfBuffer; i++)
            {
                _bufferInuseFlags[i] = false;
            }
        }
        
        // cleanup audio session
        if (_audioSessionInitialized)
        {
            OSStatus error = AudioSessionSetActive(false);
            if (error)
            {
                [self failedWithErrorCode:error];
            }
        }
        
        // reset iVars
        _status = TMAudioPlayerStatusIdle;
    }
}

-(void)initializeAudioSession
{
    if (!_audioSessionInitialized)
    {
        OSStatus error = AudioSessionInitialize(NULL,  NULL, tm_AudioSessionInterruptionListener, (__bridge void *)(self));
        if (error)
        {
            // audio session initialize error
            [self failedWithErrorCode:error];
//            return;
        }
        
        _audioSessionInitialized = YES;
        
        UInt32 sessionCategory = kAudioSessionCategory_MediaPlayback;
        AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(sessionCategory), &sessionCategory);
        
        // route change(如:耳机插拔)
        AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, tm_AudioSessionPropertyListener, (__bridge void *)(self));
        AudioSessionAddPropertyListener(kAudioSessionProperty_ServerDied, tm_AudioSessionPropertyListener, (__bridge void *)(self));
    }
    
    OSStatus error = AudioSessionSetActive(true);
    if (error)
    {
        // set active error
        [self failedWithErrorCode:error];
//        return;
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
        OSStatus error = AudioQueueNewOutput(&_audioStremDescription, tm_AudioQueueOutputCallback, (__bridge void *)(self), NULL, NULL, 0, &_audioQueue);
        if (error)
        {
            [self failedWithErrorCode:error];
            [self stop];
            return;
        }
        
        // listening the "isRunning" property
        AudioQueueAddPropertyListener(_audioQueue, kAudioQueueProperty_IsRunning, tm_AudioQueueIsRunningCallback, (__bridge void *)(self));
        
        // allocate audio queue buffers
        for (unsigned int i = 0; i < kAQNumberOfBuffer; ++i)
        {
            OSStatus error = AudioQueueAllocateBuffer(_audioQueue, kAQDefaultBufSize, &_audioQueueBuffers[i]);
            if (error)
            {
                // alloc queue error
                [self failedWithErrorCode:error];
//                return;
            }
        }
    }
}

-(void)setupAudioStream
{
    if (_audioStream == nil)
    {
        OSStatus error = AudioFileStreamOpen((__bridge void *)(self), tm_AudioStreamPropertyListenerProc, tm_AudioStreamPacketsProc, kAudioFileMP3Type, &_audioStream);
        if(error)
        {
            // open audio file stream error
            [self failedWithErrorCode:error];
            [self stop];
            
            return;
        }
    }
}

-(BOOL)isAudioQueueRunning
{
    UInt32 isRunning = 0;
    if (_audioQueue)
    {
        UInt32 ioDataSize = sizeof(isRunning);
        AudioQueueGetProperty(_audioQueue, kAudioQueueProperty_IsRunning, &isRunning, &ioDataSize);
    }
    
    return (isRunning > 0);
}

-(void)failedWithErrorCode:(NSInteger)errorCode
{
    TMNSLogError(@"Audio player error:%d", errorCode);
}

// 当下载和播放都已结束时，结束掉audio queue，并通知状态更新
-(void)finishAudioPlayingIfNecessary
{
    if (_audioStreamingFinished)
    {
        // 检查是否所有的buffer都已经处于空闲
        for (int i = 0; i != kAQNumberOfBuffer; i++)
        {
            if (_bufferInuseFlags[i])
            {
                // 还有buffer处于使用中，
                return;
            }
        }
        
        // 到这里说明所有buffer都为空，且下载流也已结束，可以结束播放了
        [self stop];
    }
}

#pragma mark - Enqueue Buffer
-(void)enqueueBuffer
{
	@synchronized(self)
	{
        if (_status == TMAudioPlayerStatusFinishing)
        {
            return;
        }
        
		_bufferInuseFlags[_fillingBufferIndex] = true;		// set in use flag
		_buffersUsed++;
        
		// enqueue buffer
		AudioQueueBufferRef fillBuf = _audioQueueBuffers[_fillingBufferIndex];
		fillBuf->mAudioDataByteSize = _numberOfFilledBytes;
		
		if (_numberOfFilledPackets > 0)
		{
			AudioQueueEnqueueBuffer(_audioQueue, fillBuf, _numberOfFilledPackets, _packetDescriptions);
		}
		else
		{
            AudioQueueEnqueueBuffer(_audioQueue, fillBuf, 0, NULL);
		}
        
        // start queue
        // TODO: 这里调用start的情况需要考虑
        if (_status != TMAudioPlayerStatusPaused)
        {
            if (![self isAudioQueueRunning])
            {
                OSStatus error = AudioQueueStart(_audioQueue, NULL);
                if (error)
                {
                    [self failedWithErrorCode:error];
                }
            }
        }
        
		// go to next buffer
        if (++_fillingBufferIndex >= kAQNumberOfBuffer)
        {
            // 回到第一个buffer
            _fillingBufferIndex = 0;
        }
        
        _numberOfFilledBytes = 0;
        _numberOfFilledPackets = 0;
	}
    
	// 如果下一个buffer正在被使用，则等待知道下一个buffer空闲
	pthread_mutex_lock(&_queueBuffersMutex);
	while (_bufferInuseFlags[_fillingBufferIndex])
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
    // 因为这个回调总是在主线程，所以为了防止主线程被挂起，在线程中执行操作
    if (inInterruptionState == kAudioSessionBeginInterruption)
    {
        if ([self isPlaying] || [self isPaused])
        {
            [self stop];
        }
    }
    else if (inInterruptionState == kAudioSessionEndInterruption)
    {
        // 因为所有中断都停止播放，所以就不需要恢复了
//        UInt32 shouldResume;
//        UInt32 flagSize = sizeof(shouldResume);
//        AudioSessionGetProperty(kAudioSessionProperty_InterruptionType, &flagSize, &shouldResume);
//        if (shouldResume == kAudioSessionInterruptionType_ShouldResume)
//        {
//            [self resume];
//        }
//        else
//        {
//            TMNSLogInfo(@"Interrupt end, but should not resume.");
//        }
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
    switch (inID)
    {
        case kAudioSessionProperty_AudioRouteChange:
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
                        [self stop];
                    }
                }
            }
        }
            break;
        case kAudioSessionProperty_ServerDied:
        {
            TMNSLogError(@"Music server has died.");
            [self failedWithErrorCode:'died'];
            [self stop];
        }
            break;
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
    
    // 如果有描述信息，表示使用的是VBR(动态比特率)，否则是CBR(固定比特率)
    if (inPacketDescriptions)
    {
        for (int i = 0; i < inNumberPackets; ++i)
		{
			SInt64 packetOffset = inPacketDescriptions[i].mStartOffset;
			SInt64 packetSize   = inPacketDescriptions[i].mDataByteSize;
			size_t bufSpaceRemaining = kAQDefaultBufSize - _numberOfFilledBytes;
            
			// 当前buffer已经不能包含完整个包，就入队(enqueue)，将该包放入下一个buffer
            // 否则，继续将包拷贝到当前buffer中
			if (bufSpaceRemaining < packetSize)
			{
                [self enqueueBuffer];
			}
			
			@synchronized(self)
			{
				//
				// If there was some kind of issue with enqueueBuffer and we didn't
				// make space for the new audio data then back out
				//
				if (_numberOfFilledBytes + packetSize > kAQDefaultBufSize)
				{
					return;
				}
				
				// 当前包放入当前buffer
				AudioQueueBufferRef fillBuf = _audioQueueBuffers[_fillingBufferIndex];
				memcpy((char*)fillBuf->mAudioData + _numberOfFilledBytes, (const char*)inInputData + packetOffset, packetSize);
                
				// fill out packet description
				_packetDescriptions[_numberOfFilledPackets] = inPacketDescriptions[i];
				_packetDescriptions[_numberOfFilledPackets].mStartOffset = _numberOfFilledBytes;
                
				// keep track of bytes filled and packets filled
				_numberOfFilledBytes += packetSize;
				_numberOfFilledPackets += 1;
			}
			
			// if that was the last free packet description, then enqueue the buffer.
			size_t packetsDescsRemaining = kAQMaxPacketDescriptions - _numberOfFilledPackets;
			if (packetsDescsRemaining == 0)
            {
                [self enqueueBuffer];
			}
		}
    }
    else
    {
        size_t offset = 0;
		while (inNumberBytes > 0)
		{
			// 如果当前buffer没有足够空间，则将buffer放入queue队列，然后填充下一个buffer
			size_t bufSpaceRemaining = kAQDefaultBufSize - _numberOfFilledBytes;
			if (bufSpaceRemaining < inNumberBytes)
			{
                [self enqueueBuffer];
			}
			
			@synchronized(self)
			{
				bufSpaceRemaining = kAQDefaultBufSize - _numberOfFilledBytes;
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
				if (_numberOfFilledBytes > kAQDefaultBufSize)
				{
					return;
				}
				
				// copy data to the audio queue buffer
				AudioQueueBufferRef fillBuf = _audioQueueBuffers[_fillingBufferIndex];
				memcpy((char*)fillBuf->mAudioData + _numberOfFilledBytes, (const char*)(inInputData + offset), copySize);
                
				_numberOfFilledBytes += copySize;
                _numberOfFilledPackets = 0;
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
	for (unsigned int i = 0; i < kAQNumberOfBuffer; ++i)
	{
		if (inBuffer == _audioQueueBuffers[i])
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
        
        [self finishAudioPlayingIfNecessary];
        
		return;
	}

	// signal waiting thread that the buffer is free.
	pthread_mutex_lock(&_queueBuffersMutex);
	_bufferInuseFlags[bufIndex] = false;
	_buffersUsed--;
    
    pthread_cond_signal(&_queueBufferReadyCondition);
	pthread_mutex_unlock(&_queueBuffersMutex);
    
    [self finishAudioPlayingIfNecessary];
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
    return (_status != TMAudioPlayerStatusPaused && _status != TMAudioPlayerStatusFinishing);
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
    [self failedWithErrorCode:error];
    
    [self stop];
}

-(void)audioStreamingOperationDidFinish:(TMAudioStreamingOperation *)aso
{
    _audioStreamingFinished = YES;
//    [self stop];
}

-(long)audioStreamingOperationRequestEachPacketLength:(TMAudioStreamingOperation *)aso
{
    return kAQDefaultBufSize;
}

@end

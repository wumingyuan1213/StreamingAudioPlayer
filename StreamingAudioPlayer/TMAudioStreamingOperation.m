//
//  TMAudioStreamingOperation.m
//  StreamingAudioPlayerFun
//
//  Created by harperzhang on 13-4-1.
//  Copyright (c) 2013年 harperzhang. All rights reserved.
//

#import "TMAudioStreamingOperation.h"
#import <CFNetwork/CFNetwork.h>
#import <sys/errno.h>

#define kDefaultReadLength 2048

@interface TMAudioStreamingOperation()

@property(nonatomic) BOOL  completed;

-(void)handleReadFromStream:(CFReadStreamRef)stream eventType:(CFStreamEventType)eventType;

@end

@implementation TMAudioStreamingOperation
{
    BOOL   _tm_isExecuting;
    BOOL   _tm_isFinished;
    
    NSURL* _url;
    CFReadStreamRef   _stream;
}

#pragma mark - Init
-(id)initWithURL:(NSURL *)url
{
    self = [super init];
    if (self)
    {
        _url = url;
    }
    
    return self;
}

-(void)dealloc
{
    TMNSLogInfo(@"dealloc() in operation.");
    [self cleanup];
}

-(void)cleanup
{
    _url = nil;
    
    if (_stream)
    {
        CFReadStreamUnscheduleFromRunLoop(_stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
        CFReadStreamClose(_stream);
        CFRelease(_stream);
        _stream = nil;
    }
}

#pragma mark - Operation methods override
-(void)start
{
    if ([self isCancelled])
    {
        goto finished;
    }
    
    [self willChangeValueForKey:@"isExecuting"];
    [self willChangeValueForKey:@"isFinished"];
    _tm_isExecuting = YES;
    _tm_isFinished = NO;
    [self didChangeValueForKey:@"isFinished"];
    [self didChangeValueForKey:@"isExecuting"];
    
    // build streamer, and schedule it in current runloop
    if ([self setupStream])
    {
        // start runloop
        while (![self completed])
        {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
        }
    }
    
finished:
    [self willChangeValueForKey:@"isExecuting"];
    [self willChangeValueForKey:@"isFinished"];
    _tm_isExecuting = NO;
    _tm_isFinished = YES;
    [self didChangeValueForKey:@"isFinished"];
    [self didChangeValueForKey:@"isExecuting"];
}

-(BOOL)isExecuting
{
    return _tm_isExecuting;
}

-(BOOL)isFinished
{
    return _tm_isFinished;
}

-(BOOL)isConcurrent
{
    return YES;
}

#pragma mark - Property
-(BOOL)completed
{
    if ([self isCancelled] || [self isFinished])
    {
        return YES;
    }
    
    // 数据未读取完，不能退出
    if (_stream && CFReadStreamHasBytesAvailable(_stream))
    {
        return NO;
    }
    
    // 被设置为完成
    return _completed;
}

#pragma mark - Stream
-(BOOL)setupStream
{
    CFHTTPMessageRef message = CFHTTPMessageCreateRequest(NULL, (CFStringRef)@"GET", (__bridge CFURLRef)_url, kCFHTTPVersion1_1);
    
    // QQ music header
    if ([[_url host] rangeOfString:@"qq.com"].location != NSNotFound)
    {
        [self fillQQMusicHeaderIntoHTTPMessage:message];
    }
    
    // setup stream
    _stream = CFReadStreamCreateForHTTPRequest(NULL, message);
    CFRelease(message);
    
    // enable redirection
    CFReadStreamSetProperty(_stream,
                                kCFStreamPropertyHTTPShouldAutoredirect,
                                kCFBooleanTrue);
    
    // proxy
    CFDictionaryRef proxySettings = CFNetworkCopySystemProxySettings();
    CFReadStreamSetProperty(_stream, kCFStreamPropertyHTTPProxy, proxySettings);
    CFRelease(proxySettings);
    
    // open stream
    if (!CFReadStreamOpen(_stream))
    {
        CFRelease(_stream);
        _stream = nil;
        
        TMNSLogError(@"Audio player CFReadStreamOpen failed.");
        
        [self.delegate audioStreamingOperation:self failedWithError:[NSError errorWithDomain:@"come.tencent" code:1 userInfo:nil]];
        
        return NO;
    }
    
    // callback function
    CFStreamClientContext context = {0, (__bridge void *)(self), NULL, NULL, NULL};
    CFReadStreamSetClient(_stream, kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered, readStreamCallBack, &context);
    
    // schedule
    CFReadStreamScheduleWithRunLoop(_stream, [[NSRunLoop currentRunLoop] getCFRunLoop], (__bridge CFStringRef)NSDefaultRunLoopMode);
    
    return YES;
}

-(void)fillQQMusicHeaderIntoHTTPMessage:(CFHTTPMessageRef)message
{
    CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Cookie"),(CFStringRef)(@"qqmusic_fromtag=18"));
    CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Referer"),(__bridge CFStringRef)([_url host]));
}

#pragma mark - Stream callback
static void readStreamCallBack(CFReadStreamRef aStream, CFStreamEventType eventType, void* inClientInfo)
{
    TMAudioStreamingOperation* operation = (__bridge TMAudioStreamingOperation*)inClientInfo;
    [operation handleReadFromStream:aStream eventType:eventType];
}

-(void)handleReadFromStream:(CFReadStreamRef)stream eventType:(CFStreamEventType)eventType
{
    switch (eventType)
    {
        case kCFStreamEventHasBytesAvailable:
        {
            // 可以继续读的情况下才继续读
            if ([self.delegate shouldAudioStreamingOperationContinueReading:self])
            {
                // 每次读取数据的大小
                long expectLength = kDefaultReadLength;
                if ([self.delegate respondsToSelector:@selector(audioStreamingOperationRequestEachPacketLength:)])
                {
                    expectLength = [self.delegate audioStreamingOperationRequestEachPacketLength:self];
                }
                
                UInt8 bytes[expectLength];
                CFIndex length;
                
                // 不读出来就不会继续
                length = CFReadStreamRead(stream, bytes, expectLength);
                
                [self.delegate audioStreamingOperation:self didReadBytes:bytes length:length];
            }
        }
            break;
        case kCFStreamEventEndEncountered:
        {
            TMNSLogInfo(@"stream event end.");
            
            [self cleanup];
            
            [self.delegate audioStreamingOperationDidFinish:self];
            
            _completed = YES;
        }
            break;
        case kCFStreamEventErrorOccurred:
        {
            CFStreamError error = CFReadStreamGetError(_stream);
            TMNSLogError(@"Audio player CFStream event error, domain:%ld code:%ld", error.domain, error.error);
            
            [self cleanup];
            
            [self.delegate audioStreamingOperation:self failedWithError:[NSError errorWithDomain:@"com.tencent.weibo" code:error.error userInfo:nil]];
            
            _completed = YES;
        }
            break;
        default:
        {
            TMNSLogError(@"Unknown event type:%ld", eventType);
            
            _completed = YES;
        }
            break;
    }
}


@end

//
//  TMAudioStreamingOperation.m
//  StreamingAudioPlayerFun
//
//  Created by harperzhang on 13-4-1.
//  Copyright (c) 2013年 harperzhang. All rights reserved.
//

#import "TMAudioStreamingOperation.h"
#import <CFNetwork/CFNetwork.h>

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
    NSLog(@"dealloc() in operation.");
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
    if ([self isCancelled]) return;
    
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
        
        NSLog(@"Open stream failed.");
        
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
                UInt8 bytes[2048];
                CFIndex length;
                
                // 不读出来就不会继续
                length = CFReadStreamRead(stream, bytes, 2048);
                
                [self.delegate audioStreamingOperation:self didReadBytes:bytes length:length];
            }
        }
            break;
        case kCFStreamEventEndEncountered:
        {
            NSLog(@"stream event end.");
            
            [self.delegate audioStreamingOperationDidFinish:self];
            
            [self cleanup];
            
            _completed = YES;
        }
            break;
        case kCFStreamEventErrorOccurred:
        {
            CFStreamError error = CFReadStreamGetError(_stream);
            NSLog(@"stream event error, code:%ld", error.error);
            
            if (error.domain == kCFStreamErrorDomainPOSIX && error.error == 54)
            {
                // 链接被重置，这个错误码意义和普通退出一样，不能识别为错误码
                break;
            }
            
            [self cleanup];
            
            [self.delegate audioStreamingOperation:self failedWithError:[NSError errorWithDomain:@"com.tencent.weibo" code:error.error userInfo:nil]];
        }
            break;
        default:
        {
            NSLog(@"Unknown event type:%ld", eventType);
        }
            break;
            
    }
}


@end

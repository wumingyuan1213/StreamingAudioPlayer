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
    [self setupStream];
    
    // start runloop
    while (!self.completed)
    {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
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
    // 被设置为完成，或已被取消，或已结束执行
    return (_completed || [self isCancelled] || [self isFinished]);
}

#pragma mark - Stream
-(BOOL)setupStream
{
    CFHTTPMessageRef message = CFHTTPMessageCreateRequest(NULL, (CFStringRef)@"GET", (__bridge CFURLRef)_url, kCFHTTPVersion1_1);
    
    // setup stream
    _stream = CFReadStreamCreateForHTTPRequest(NULL, message);
    CFRelease(message);
    
    // enable redirection
    if (CFReadStreamSetProperty(_stream,
                                kCFStreamPropertyHTTPShouldAutoredirect,
                                kCFBooleanTrue) == false)
    {
        // set property failed
        NSLog(@"Set property failed.");
        return NO;
    }
    
    // proxy
    CFDictionaryRef proxySettings = CFNetworkCopySystemProxySettings();
    CFReadStreamSetProperty(_stream, kCFStreamPropertyHTTPProxy, proxySettings);
    CFRelease(proxySettings);
    
    // open stream
    if (!CFReadStreamOpen(_stream))
    {
        CFRelease(_stream);
        
        NSLog(@"Open stream failed.");
        return NO;
    }
    
    // callback function
    CFStreamClientContext context = {0, (__bridge void *)(self), NULL, NULL, NULL};
    CFReadStreamSetClient(_stream, kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered, readStreamCallBack, &context);
    
    // schedule
    CFReadStreamScheduleWithRunLoop(_stream, [[NSRunLoop currentRunLoop] getCFRunLoop], (__bridge CFStringRef)NSDefaultRunLoopMode);
    
    return YES;
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
            UInt8 bytes[2048];
            CFIndex length;
            
            // 不读出来就不会继续
            length = CFReadStreamRead(stream, bytes, 2048);
            
            
        }
            break;
        case kCFStreamEventEndEncountered:
        {
            NSLog(@"stream event end.");
            _completed = YES;
        }
            break;
        default:
            break;
            
    }
}


@end

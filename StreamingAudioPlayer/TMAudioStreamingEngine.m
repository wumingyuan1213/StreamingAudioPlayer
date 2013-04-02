//
//  TMAudioStreamingEngine.m
//  StreamingAudioPlayerFun
//
//  Created by harperzhang on 13-4-1.
//  Copyright (c) 2013年 harperzhang. All rights reserved.
//

#import "TMAudioStreamingEngine.h"
#import <CFNetwork/CFNetwork.h>

@interface TMAudioStreamingEngine()

-(void)handleReadFromStream:(CFReadStreamRef)stream eventType:(CFStreamEventType)eventType;

@end

@implementation TMAudioStreamingEngine
{
    CFReadStreamRef   _stream;
}

#pragma mark - Thread
+ (void) __attribute__((noreturn)) networkRequestThreadEntryPoint:(id)__unused object {
    do {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] run];
        }
    } while (YES);
}

+ (NSThread *)networkRequestThread {
    static NSThread *_networkRequestThread = nil;
    static dispatch_once_t oncePredicate;
    
    dispatch_once(&oncePredicate, ^{
        _networkRequestThread = [[NSThread alloc] initWithTarget:self selector:@selector(networkRequestThreadEntryPoint:) object:nil];
        [_networkRequestThread start];
    });
    
    return _networkRequestThread;
}

#pragma mark - Initialize
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
    NSLog(@"dealloc() of engine.");
}

#pragma mark - Schedule
-(void)start
{
    [self performSelector:@selector(perform) onThread:[[self class] networkRequestThread] withObject:nil waitUntilDone:NO modes:@[NSDefaultRunLoopMode]];
}

-(void)perform
{
    if (![self setupStream]) return;
    
    NSRunLoop* runloop = [NSRunLoop currentRunLoop];
    CFReadStreamScheduleWithRunLoop(_stream, [runloop getCFRunLoop], (__bridge CFStringRef)NSDefaultRunLoopMode);
}

#pragma mark - Tools
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
    
    return YES;
}

#pragma mark - Stream callback
static void readStreamCallBack(CFReadStreamRef aStream, CFStreamEventType eventType, void* inClientInfo)
{
    TMAudioStreamingEngine*  engine = (__bridge TMAudioStreamingEngine*)inClientInfo;
    [engine handleReadFromStream:aStream eventType:eventType];
}

-(void)handleReadFromStream:(CFReadStreamRef)stream eventType:(CFStreamEventType)eventType
{
    UInt8 bytes[2048];
    CFIndex length;
    
    // 不读出来就不会继续
    length = CFReadStreamRead(stream, bytes, 2048);
    
    
    NSLog(@"in handle read stream. event:%ld, length:%ld", eventType, length);

}

@end

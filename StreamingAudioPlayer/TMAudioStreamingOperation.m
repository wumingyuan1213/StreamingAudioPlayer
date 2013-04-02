//
//  TMAudioStreamingOperation.m
//  StreamingAudioPlayerFun
//
//  Created by harperzhang on 13-4-1.
//  Copyright (c) 2013年 harperzhang. All rights reserved.
//

#import "TMAudioStreamingOperation.h"
#import "TMAudioStreamingEngine.h"

@implementation TMAudioStreamingOperation
{
    BOOL   _tm_isExecuting;
    BOOL   _tm_isFinished;

    NSURL* _url;
    TMAudioStreamingEngine*  _engine;
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
    _tm_isExecuting = YES;
    [self didChangeValueForKey:@"isExecuting"];
    
    _engine = [[TMAudioStreamingEngine alloc] initWithURL:_url];
    
    // schedule
    [_engine start];
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

@end

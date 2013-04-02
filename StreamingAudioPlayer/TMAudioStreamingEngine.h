//
//  TMAudioStreamingEngine.h
//  StreamingAudioPlayerFun
//
//  Created by harperzhang on 13-4-1.
//  Copyright (c) 2013年 harperzhang. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface TMAudioStreamingEngine : NSObject

@property(nonatomic, readonly) NSURL*   url;

- (id)initWithURL:(NSURL*)url;

- (void)start;

@end

//
//  TMAudioStreamingOperation.h
//  StreamingAudioPlayerFun
//
//  Created by harperzhang on 13-4-1.
//  Copyright (c) 2013年 harperzhang. All rights reserved.
//

#import <Foundation/Foundation.h>

@protocol TMAudioStreamingOperationDelegate;
@interface TMAudioStreamingOperation : NSOperation

@property(nonatomic, unsafe_unretained) id<TMAudioStreamingOperationDelegate> delegate;

-(id)initWithURL:(NSURL*)url;

@end


@protocol TMAudioStreamingOperationDelegate <NSObject>

@required
-(void)audioStreamingOperation:(TMAudioStreamingOperation*)aso didReadBytes:(unsigned char*)bytes length:(long long)length;

@end
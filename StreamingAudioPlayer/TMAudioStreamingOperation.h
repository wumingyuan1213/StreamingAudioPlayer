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

/**
 读取到数据了，传递出去用于播放
 */
-(void)audioStreamingOperation:(TMAudioStreamingOperation*)aso didReadBytes:(unsigned char*)bytes length:(long long)length;

/**
 询问是否继续读取数据
 */
-(BOOL)shouldAudioStreamingOperationContinueReading:(TMAudioStreamingOperation*)aso;

/**
 询问是否可以退出了
 
 因为operation持有着数据流，所以在所有数据到达AudioQueue之前不应该退出
 
 @param errorCode 错误码，CFStreamError中的error字段
 */
-(void)audioStreamingOperation:(TMAudioStreamingOperation*)aso failedWithError:(long)errorCode;

@end
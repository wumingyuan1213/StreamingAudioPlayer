//
//  TMAudioStreamingOperation.h
//  StreamingAudioPlayerFun
//
//  Created by harperzhang on 13-4-1.
//  Copyright (c) 2013年 harperzhang. All rights reserved.
//

#import <Foundation/Foundation.h>



/**
 音频流式下载的operation类
 */
@protocol TMAudioStreamingOperationDelegate;
@interface TMAudioStreamingOperation : NSOperation

@property(nonatomic, unsafe_unretained) id<TMAudioStreamingOperationDelegate> delegate;

/**
 初始化并返回对象
 
 @param url 用于初始化的url
 @return 初始化好的对象
 */
-(id)initWithURL:(NSURL*)url;

@end


@protocol TMAudioStreamingOperationDelegate <NSObject>

@required

/**
 读取到数据了，传递出去用于播放
 
 @param aso TMAudioStreamingOperation对象
 @param bytes 读取到的数据流
 @param length 数据流的长度
 */
-(void)audioStreamingOperation:(TMAudioStreamingOperation*)aso didReadBytes:(unsigned char*)bytes length:(long long)length;

/**
 询问是否继续读取数据
 
 @param aso TMAudioStreamingOperation对象
 */
-(BOOL)shouldAudioStreamingOperationContinueReading:(TMAudioStreamingOperation*)aso;

/**
 询问是否可以退出了
 
 因为operation持有着数据流，所以在所有数据到达AudioQueue之前不应该退出
 
 @param aso TMAudioStreamingOperation对象
 @param errorCode 错误码，CFStreamError中的error字段
 */
-(void)audioStreamingOperation:(TMAudioStreamingOperation*)aso failedWithError:(NSError*)error;

/**
 已经结束读取
 
 @param aso TMAudioStreamingOperation对象
 */
-(void)audioStreamingOperationDidFinish:(TMAudioStreamingOperation*)aso;

@end
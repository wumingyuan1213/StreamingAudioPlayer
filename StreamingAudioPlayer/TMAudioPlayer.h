//
//  TMAudioPlayer.h
//  StreamingAudioPlayerFun
//
//  Created by Harper Zhang on 13-4-2.
//  Copyright (c) 2013年 harperzhang. All rights reserved.
//

#import <Foundation/Foundation.h>

/**
 用于音乐播放，这里包含播放以及下载
 */
@interface TMAudioPlayer : NSObject

@property(nonatomic, readonly) NSURL*  audioURL;

/**
 播放URL对应的音乐
 
 @param audioURL 将要播放的音乐对应URL
 */
-(void)playAudioWithURL:(NSURL*)audioURL;

/**
 停止播放
 */
-(void)stop;

/**
 是否正在播放
 
 @return YES 正在播放或者加载缓冲中， NO 空闲或暂停状态
 */
-(BOOL)isPlaying;

@end

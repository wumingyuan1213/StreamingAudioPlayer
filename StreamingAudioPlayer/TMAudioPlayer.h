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
@protocol TMAudioPlayerDelegate;
@interface TMAudioPlayer : NSObject

@property(nonatomic, unsafe_unretained) id<TMAudioPlayerDelegate> delegate;
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
 暂停播放
 
 用于在遇到电话、其他音乐播放等中断时内部使用，中断解除后将继续播放；或点击视频播放时调用暂停
 */
-(void)pause;

/**
 暂停后的恢复播放
 */
-(void)resume;

/**
 是否正在播放
 
 @return YES 正在播放或者加载缓冲中， NO 空闲或暂停状态
 */
-(BOOL)isPlaying;

/**
 是否处于暂停状态
 
 @return YES 正处于暂停状态，NO 不处于暂停状态
 */
-(BOOL)isPaused;

@end

#pragma mark - TMAudioPlayerDelegate
@protocol TMAudioPlayerDelegate <NSObject>

@required
/**
 状态改变
 
 @param audioPlayer 播放音乐的TMAudioPlayer对象
 */
-(void)audioPlayerDidChangeStatus:(TMAudioPlayer*)audioPlayer;

@end
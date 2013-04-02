//
//  TMAudioPlayer.h
//  StreamingAudioPlayerFun
//
//  Created by Harper Zhang on 13-4-2.
//  Copyright (c) 2013年 harperzhang. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface TMAudioPlayer : NSObject

@property(nonatomic, readonly) NSURL*  audioURL;

-(void)playAudioWithURL:(NSURL*)audioURL;


@end

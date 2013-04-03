//
//  SAViewController.m
//  StreamingAudioPlayerFun
//
//  Created by harperzhang on 13-3-30.
//  Copyright (c) 2013年 harperzhang. All rights reserved.
//

#import "SAViewController.h"
#import "TMAudioStreamingOperation.h"
#import "TMAudioPlayer.h"

@interface SAViewController ()

- (IBAction)playButtonAction:(id)sender;
- (IBAction)stopButtonAction:(id)sender;

@end

@implementation SAViewController
{
    TMAudioPlayer*  _player;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view, typically from a nib.
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (IBAction)playButtonAction:(id)sender
{
    if (_player == nil)
    {
        _player = [[TMAudioPlayer alloc] init];
    }
    
    //    NSURL* url = [NSURL URLWithString:@"http://ht.salemweb.net/ccm/tcm/album-tracks-clips/AnthemLights/AnthemLightsEP/01_CantShutUp.mp3"];
    //    NSURL* url = [NSURL URLWithString:@"http://stream15.qqmusic.qq.com/30831466.mp3"]; // 这个用audiostreamer不能播
    NSURL* url = [NSURL URLWithString:@"http://stream15.qqmusic.qq.com/34781082.mp3"]; // 夜夜夜夜
    [_player playAudioWithURL:url];
    //    NSOperationQueue* queue = [[NSOperationQueue alloc] init];
    //
    //    TMAudioStreamingOperation* operation = [[TMAudioStreamingOperation alloc] initWithURL:url];
    //    [queue addOperation:operation];
}

- (IBAction)stopButtonAction:(id)sender
{
    [_player stop];
}

@end

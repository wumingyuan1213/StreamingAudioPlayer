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

@end

@implementation SAViewController
{
    TMAudioPlayer*  _player;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view, typically from a nib.
    
    if (_player == nil)
    {
        _player = [[TMAudioPlayer alloc] init];
    }
    
    NSURL* url = [NSURL URLWithString:@"http://ht.salemweb.net/ccm/tcm/album-tracks-clips/AnthemLights/AnthemLightsEP/01_CantShutUp.mp3"];
    [_player playAudioWithURL:url];
//    NSOperationQueue* queue = [[NSOperationQueue alloc] init];
//    
//    TMAudioStreamingOperation* operation = [[TMAudioStreamingOperation alloc] initWithURL:url];
//    [queue addOperation:operation];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

@end

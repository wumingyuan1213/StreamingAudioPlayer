//
//  SAViewController.m
//  StreamingAudioPlayerFun
//
//  Created by harperzhang on 13-3-30.
//  Copyright (c) 2013年 harperzhang. All rights reserved.
//

#import "SAViewController.h"
#import "TMAudioStreamingOperation.h"
#import "TMAudioStreamingEngine.h"

@interface SAViewController ()

@end

@implementation SAViewController
{
    TMAudioStreamingEngine* _engine;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view, typically from a nib.
    
    NSURL* url = [NSURL URLWithString:@"http://ht.salemweb.net/ccm/tcm/album-tracks-clips/AnthemLights/AnthemLightsEP/01_CantShutUp.mp3"];
    
//    _engine = [[TMAudioStreamingEngine alloc] initWithURL:url];
//    [_engine start];
    
    NSOperationQueue* queue = [[NSOperationQueue alloc] init];
    
    TMAudioStreamingOperation* operation = [[TMAudioStreamingOperation alloc] initWithURL:url];
    [queue addOperation:operation];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

@end

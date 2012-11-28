//
//  UnityAdsAdViewController.m
//  UnityAds
//
//  Created by bluesun on 11/21/12.
//  Copyright (c) 2012 Unity Technologies. All rights reserved.
//

#import "UnityAdsMainViewController.h"
#import "UnityAds.h"
#import "UnityAdsVideo/UnityAdsVideoView.h"
#import "UnityAdsCampaign/UnityAdsCampaignManager.h"
#import "UnityAdsCampaign/UnityAdsCampaign.h"
#import "UnityAdsProperties/UnityAdsProperties.h"

@interface UnityAdsMainViewController ()
  @property (nonatomic, strong) UnityAdsVideoViewController *videoController;
  @property (nonatomic, strong) UIViewController *storeController;
@end

@implementation UnityAdsMainViewController

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
  
    if (self) {
      // Add notification listener
      NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
      [notificationCenter addObserver:self selector:@selector(notificationHandler:) name:UIApplicationDidEnterBackgroundNotification object:nil];
      
      // Start WebAppController
      [UnityAdsWebAppController sharedInstance];
      [[UnityAdsWebAppController sharedInstance] setDelegate:self];
      
      // Init VideoController (ios6)
      if (kCFCoreFoundationVersionNumber > kCFCoreFoundationVersionNumber_iOS_5_1) {
        UALOG_DEBUG(@"Initializing videoController only once in iOS6");
        [self _createVideoController];
      }
    }
  
    return self;
}

- (void)dealloc {
	UALOG_DEBUG(@"");
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self _destroyVideoController];
}

- (void)viewDidLoad {
	UALOG_DEBUG(@"");
  [self.view setBackgroundColor:[UIColor blackColor]];
  [super viewDidLoad];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}


#pragma mark - Orientation handling

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation {
  return YES;
}

- (NSUInteger)supportedInterfaceOrientations {
  UALOG_DEBUG(@"");
  return UIInterfaceOrientationMaskAll;
}

- (BOOL) shouldAutorotate {
  return YES;
}

#pragma mark - Public

- (BOOL)closeAds {
  UALOG_DEBUG(@"");
  if (self.videoController.view.superview != nil) {
    [self dismissViewControllerAnimated:NO completion:nil];
  }
  [[[UnityAdsProperties sharedInstance] currentViewController] dismissViewControllerAnimated:YES completion:nil];
  return YES;
}

- (BOOL)openAds {
  UALOG_DEBUG(@"");
  [[UnityAdsWebAppController sharedInstance] setWebViewCurrentView:@"start" data:@{}];
  [[[UnityAdsProperties sharedInstance] currentViewController] presentViewController:self animated:YES completion:nil];
  
  if (![[[[UnityAdsWebAppController sharedInstance] webView] superview] isEqual:self.view]) {
    [self.view addSubview:[[UnityAdsWebAppController sharedInstance] webView]];
    [[[UnityAdsWebAppController sharedInstance] webView] setFrame:self.view.bounds];
  }
  
  return YES;
}

- (BOOL)mainControllerVisible {
  if (self.view.superview != nil) {
    return YES;
  }
  
  return NO;
}


#pragma mark - Video

- (void)videoPlayerStartedPlaying {
  [self.delegate mainControllerStartedPlayingVideo];
  [[UnityAdsWebAppController sharedInstance] sendNativeEventToWebApp:@"hideSpinner" data:@{@"textKey":@"buffering"}];
  [[UnityAdsWebAppController sharedInstance] setWebViewCurrentView:kUnityAdsWebViewViewTypeCompleted data:@{}];
  [self presentViewController:self.videoController animated:NO completion:nil];
}

- (void)videoPlayerPlaybackEnded {
  [self.delegate mainControllerVideoEnded];
  [self dismissViewControllerAnimated:NO completion:nil];
  
  if (kCFCoreFoundationVersionNumber <= kCFCoreFoundationVersionNumber_iOS_5_1) {
    UALOG_DEBUG(@"Destroying videoController for iOS5 compatibility");
    [self _destroyVideoController];
  }
}

- (void)showPlayerAndPlaySelectedVideo:(BOOL)checkIfWatched {
	UALOG_DEBUG(@"");
    
  if ([[UnityAdsCampaignManager sharedInstance] selectedCampaign].viewed && checkIfWatched) {
    UALOG_DEBUG(@"Trying to watch a campaign that is already viewed!");
    return;
  }

  [[UnityAdsWebAppController sharedInstance] sendNativeEventToWebApp:@"showSpinner" data:@{@"textKey":@"buffering"}];
  
  if (kCFCoreFoundationVersionNumber <= kCFCoreFoundationVersionNumber_iOS_5_1) {
    UALOG_DEBUG(@"Creating videoController for iOS5 compatibility");
    [self _createVideoController];
  }
  
  [self.videoController playCampaign:[[UnityAdsCampaignManager sharedInstance] selectedCampaign]];
}

- (void)_createVideoController {
  self.videoController = [[UnityAdsVideoViewController alloc] initWithNibName:nil bundle:nil];
  self.videoController.delegate = self;
}

- (void)_destroyVideoController {
  self.videoController.delegate = nil;
  self.videoController = nil;
}


#pragma mark - Notification receiver

- (void)notificationHandler: (id) notification {
  NSString *name = [notification name];

  UALOG_DEBUG(@"notification: %@", name);
  
  if ([name isEqualToString:UIApplicationDidEnterBackgroundNotification]) {
    [self.videoController forceStopVideoPlayer];
    [self closeAds];
  }
}


#pragma mark - AppStore opening

- (BOOL)_canOpenStoreProductViewController {
	Class storeProductViewControllerClass = NSClassFromString(@"SKStoreProductViewController");
	return [storeProductViewControllerClass instancesRespondToSelector:@selector(loadProductWithParameters:completionBlock:)];
}

- (void)openAppStoreWithData:(NSDictionary *)data {
	UALOG_DEBUG(@"");
	
  if (![self _canOpenStoreProductViewController]) {
		NSString *clickUrl = [data objectForKey:@"clickUrl"];
    if (clickUrl == nil) return;
    UALOG_DEBUG(@"Cannot open store product view controller, falling back to click URL.");
		[[UnityAdsWebAppController sharedInstance] openExternalUrl:clickUrl];
		return;
	}
  
  Class storeProductViewControllerClass = NSClassFromString(@"SKStoreProductViewController");
  if ([storeProductViewControllerClass instancesRespondToSelector:@selector(loadProductWithParameters:completionBlock:)] == YES) {
    NSString *gameId = [data objectForKey:@"iTunesId"];
    if (gameId == nil || [gameId length] < 1) return;
    NSDictionary *productParams = @{SKStoreProductParameterITunesItemIdentifier:gameId};
    self.storeController = [[storeProductViewControllerClass alloc] init];
    
    if ([self.storeController respondsToSelector:@selector(setDelegate:)]) {
      [self.storeController performSelector:@selector(setDelegate:) withObject:self];
    }
    
    void (^storeControllerComplete)(BOOL result, NSError *error) = ^(BOOL result, NSError *error) {
      UALOG_DEBUG(@"RESULT: %i", result);
      if (result) {
        [[UnityAdsWebAppController sharedInstance] sendNativeEventToWebApp:@"hideSpinner" data:@{@"textKey":@"loading"}];
        [[UnityAdsMainViewController sharedInstance] presentViewController:self.storeController animated:YES completion:nil];
      }
      else {
        UALOG_DEBUG(@"Loading product information failed: %@", error);
      }
    };
    
    [[UnityAdsWebAppController sharedInstance] sendNativeEventToWebApp:@"showSpinner" data:@{@"textKey":@"loading"}];
    SEL loadProduct = @selector(loadProductWithParameters:completionBlock:);
    if ([self.storeController respondsToSelector:loadProduct]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      [self.storeController performSelector:loadProduct withObject:productParams withObject:storeControllerComplete];
#pragma clang diagnostic pop
    }
  }
}


#pragma mark - SKStoreProductViewControllerDelegate

- (void)productViewControllerDidFinish:(SKStoreProductViewController *)viewController {
	UALOG_DEBUG(@"");
  [[UnityAdsMainViewController sharedInstance] dismissViewControllerAnimated:YES completion:nil];
}


#pragma mark - WebAppController

- (void)webAppReady {
  [self.delegate mainControllerWebViewInitialized];
}


#pragma mark - Shared Instance

static UnityAdsMainViewController *sharedMainViewController = nil;

+ (id)sharedInstance {
	@synchronized(self) {
		if (sharedMainViewController == nil) {
      sharedMainViewController = [[UnityAdsMainViewController alloc] initWithNibName:nil bundle:nil];
		}
	}
	
	return sharedMainViewController;
}

@end
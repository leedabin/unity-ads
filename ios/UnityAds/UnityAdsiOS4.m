//
//  UnityAdsiOS4.m
//  UnityAdsExample
//
//  Created by Johan Halin on 9/4/12.
//  Copyright (c) 2012 Unity Technologies. All rights reserved.
//

#include <sys/socket.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <CommonCrypto/CommonDigest.h>

#import <SystemConfiguration/SystemConfiguration.h>

#import "UnityAdsiOS4.h"
#import "UnityAdsCampaignManager.h"
#import "UnityAdsCampaign.h"
#import "UnityAdsRewardItem.h"
#import "UnityAdsOpenUDID.h"
#import "UnityAdsAnalyticsUploader.h"
#import "UnityAdsViewManager.h"

NSString * const kUnityAdsVersion = @"1.0";

@interface UnityAdsiOS4 () <UnityAdsCampaignManagerDelegate, UIWebViewDelegate, UIScrollViewDelegate, UnityAdsViewManagerDelegate>
@property (nonatomic, strong) UnityAdsCampaignManager *campaignManager;
@property (nonatomic, strong) UnityAdsAnalyticsUploader *analyticsUploader;
@property (nonatomic, strong) UnityAdsViewManager *viewManager;
@property (nonatomic, strong) UnityAdsRewardItem *rewardItem;
@property (nonatomic, strong) NSString *gameId;
@property (nonatomic, strong) NSString *campaignJSON;
@property (nonatomic, strong) NSString *machineName;
@property (nonatomic, strong) NSString *md5AdvertisingIdentifier;
@property (nonatomic, strong) NSString *md5MACAddress;
@property (nonatomic, strong) NSString *md5OpenUDID;
@property (nonatomic, strong) NSString *campaignQueryString;
@property (nonatomic, strong) NSString *gamerID;
@property (nonatomic, strong) NSString *connectionType;
@property (nonatomic, strong) NSThread *backgroundThread;
@property (nonatomic, strong) NSArray *campaigns;
@property (nonatomic, assign) BOOL webViewInitialized;
@property (nonatomic, assign) dispatch_queue_t queue;
@end

@implementation UnityAdsiOS4

#pragma mark - Private

- (NSString *)_advertisingIdentifier
{
	NSString *identifier = nil;
	
	Class advertisingManagerClass = NSClassFromString(@"ASIdentifierManager");
	if ([advertisingManagerClass respondsToSelector:@selector(sharedManager)])
	{
		id advertisingManager = [[advertisingManagerClass class] performSelector:@selector(sharedManager)];
		BOOL enabled = YES; // Not sure what to do with this value.

		if ([advertisingManager respondsToSelector:@selector(isAdvertisingTrackingEnabled)])
		{
			NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[advertisingManagerClass instanceMethodSignatureForSelector:@selector(isAdvertisingTrackingEnabled)]];
			[invocation setSelector:@selector(isAdvertisingTrackingEnabled)];
			[invocation setTarget:advertisingManager];
			[invocation invoke];
			[invocation getReturnValue:&enabled];
		}
		
		UALOG_DEBUG(@"Ad tracking %@.", enabled ? @"enabled" : @"disabled");

		if ([advertisingManager respondsToSelector:@selector(advertisingIdentifier)])
		{
			id advertisingIdentifier = [advertisingManager performSelector:@selector(advertisingIdentifier)];
			if (advertisingIdentifier != nil && [advertisingIdentifier respondsToSelector:@selector(UUIDString)])
			{
				id uuid = [advertisingIdentifier performSelector:@selector(UUIDString)];
				if ([uuid isKindOfClass:[NSString class]])
					identifier = uuid;
			}
		}
	}
	
	return identifier;
}

- (NSString *)_machineName
{
	size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char *answer = malloc(size);
	sysctlbyname("hw.machine", answer, &size, NULL, 0);
	NSString *result = [NSString stringWithCString:answer encoding: NSUTF8StringEncoding];
	free(answer);
	
	return result;
}

- (NSString *)_substringOfString:(NSString *)string toIndex:(NSInteger)index
{
	if (index > [string length])
		return nil;
	
	return [string substringToIndex:index];
}

- (NSString *)_analyticsMachineName
{
	NSString *machine = [self _machineName];
	if ([machine isEqualToString:@"iPhone1,1"])
		return @"iphone";
	else if ([machine isEqualToString:@"iPhone1,2"])
		return @"iphone3g";
	else if ([machine isEqualToString:@"iPhone2,1"])
		return @"iphone3gs";
	else if ([[self _substringOfString:machine toIndex:7] isEqualToString:@"iPhone3"])
		return @"iphone4";
	else if ([[self _substringOfString:machine toIndex:7] isEqualToString:@"iPhone4"])
		return @"iphone4s";
	else if ([[self _substringOfString:machine toIndex:7] isEqualToString:@"iPhone5"])
		return @"iphone5";
	else if ([machine isEqualToString:@"iPod1,1"])
		return @"ipodtouch1gen";
	else if ([machine isEqualToString:@"iPod2,1"])
		return @"ipodtouch2gen";
	else if ([machine isEqualToString:@"iPod3,1"])
		return @"ipodtouch3gen";
	else if ([machine isEqualToString:@"iPod4,1"])
		return @"ipodtouch4gen";
	else if ([[self _substringOfString:machine toIndex:5] isEqualToString:@"iPad1"])
		return @"ipad1";
	else if ([[self _substringOfString:machine toIndex:5] isEqualToString:@"iPad2"])
		return @"ipad2";
	else if ([[self _substringOfString:machine toIndex:5] isEqualToString:@"iPad3"])
		return @"ipad3";
    
	return @"iosUnknown";
}

- (NSString *)_macAddress
{
	NSString *interface = @"en0";
	int mgmtInfoBase[6];
	char *msgBuffer = NULL;
	
	// Setup the management Information Base (mib)
	mgmtInfoBase[0] = CTL_NET; // Request network subsystem
	mgmtInfoBase[1] = AF_ROUTE; // Routing table info
	mgmtInfoBase[2] = 0;
	mgmtInfoBase[3] = AF_LINK; // Request link layer information
	mgmtInfoBase[4] = NET_RT_IFLIST; // Request all configured interfaces
	
	// With all configured interfaces requested, get handle index
	if ((mgmtInfoBase[5] = if_nametoindex([interface UTF8String])) == 0)
	{
		UALOG_DEBUG(@"Couldn't get MAC address for interface '%@', if_nametoindex failed.", interface);
		return nil;
	}
	
	size_t length;
	
	// Get the size of the data available (store in len)
	if (sysctl(mgmtInfoBase, 6, NULL, &length, NULL, 0) < 0)
	{
		UALOG_DEBUG(@"Couldn't get MAC address for interface '%@', sysctl for mgmtInfoBase length failed.", interface);
		return nil;
	}
	
	// Alloc memory based on above call
	if ((msgBuffer = malloc(length)) == NULL)
	{
		UALOG_DEBUG(@"Couldn't get MAC address for interface '%@', malloc for %zd bytes failed.", interface, length);
		return nil;
	}
	
	// Get system information, store in buffer
	if (sysctl(mgmtInfoBase, 6, msgBuffer, &length, NULL, 0) < 0)
	{
		free(msgBuffer);
		
		UALOG_DEBUG(@"Couldn't get MAC address for interface '%@', sysctl for mgmtInfoBase data failed.", interface);
		return nil;
	}
	
	// Map msgbuffer to interface message structure
	struct if_msghdr *interfaceMsgStruct = (struct if_msghdr *) msgBuffer;
	
	// Map to link-level socket structure
	struct sockaddr_dl *socketStruct = (struct sockaddr_dl *) (interfaceMsgStruct + 1);
	
	// Copy link layer address data in socket structure to an array
	unsigned char macAddress[6];
	memcpy(&macAddress, socketStruct->sdl_data + socketStruct->sdl_nlen, 6);
	
	// Read from char array into a string object, into MAC address format
	NSString *macAddressString = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X", macAddress[0], macAddress[1], macAddress[2], macAddress[3], macAddress[4], macAddress[5]];
	
	// Release the buffer memory
	free(msgBuffer);
	
	return macAddressString;
}

- (NSString *)_md5StringFromString:(NSString *)string
{
	if (string == nil)
	{
		UALOG_DEBUG(@"Input is nil.");
		return nil;
	}
	
	const char *ptr = [string UTF8String];
	unsigned char md5Buffer[CC_MD5_DIGEST_LENGTH];
	CC_MD5(ptr, strlen(ptr), md5Buffer);
	NSMutableString *output = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
	for(int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
		[output appendFormat:@"%02x",md5Buffer[i]];
	
	return output;
}

- (NSString *)_md5OpenUDIDString
{
	return [self _md5StringFromString:[UnityAdsOpenUDID value]];
}

- (NSString *)_md5MACAddressString
{
	return [self _md5StringFromString:[self _macAddress]];
}

- (NSString *)_md5AdvertisingIdentifierString
{
	NSString *adId = [self _advertisingIdentifier];
	if (adId == nil)
	{
		UALOG_DEBUG(@"Advertising identifier not available.");
		return nil;
	}
	
	return [self _md5StringFromString:adId];
}

- (NSString *)_currentConnectionType
{
	NSString *wifiString = @"wifi";
	NSString *cellularString = @"cellular";
	NSString *connectionString = nil;
	
	SCNetworkReachabilityRef reachabilityRef = SCNetworkReachabilityCreateWithName(NULL, "unity3d.com");
	if (reachabilityRef != NULL)
	{
		SCNetworkReachabilityFlags flags;
		if (SCNetworkReachabilityGetFlags(reachabilityRef, &flags))
		{
			if ((flags & kSCNetworkReachabilityFlagsConnectionRequired) == 0)
			{
				// if target host is reachable and no connection is required
				//  then we'll assume (for now) that you're on Wi-Fi
				connectionString = wifiString;
			}
			
			if ((flags & kSCNetworkReachabilityFlagsConnectionOnDemand) != 0 || (flags & kSCNetworkReachabilityFlagsConnectionOnTraffic) != 0)
			{
				// ... and the connection is on-demand (or on-traffic) if the
				//     calling application is using the CFSocketStream or higher APIs
				
				if ((flags & kSCNetworkReachabilityFlagsInterventionRequired) == 0)
				{
					// ... and no [user] intervention is needed
					connectionString = wifiString;
				}
			}
			
			if ((flags & kSCNetworkReachabilityFlagsIsWWAN) != 0)
			{
				// ... but WWAN connections are OK if the calling application
				//     is using the CFNetwork (CFSocketStream?) APIs.
				connectionString = cellularString;
			}

			if ((flags & kSCNetworkReachabilityFlagsReachable) == 0)
			{
				// if target host is not reachable
				connectionString = nil;
			}
		}

		CFRelease(reachabilityRef);
	}
	
	return connectionString;
}

- (NSString *)_queryString
{
	NSString *advertisingIdentifier = self.md5AdvertisingIdentifier != nil ? [NSString stringWithFormat:@"&advertisingTrackingId=%@", self.md5AdvertisingIdentifier] : @"";
	
	return [NSString stringWithFormat:@"?openUdid=%@&macAddress=%@%@&iosVersion=%@&device=%@&sdkVersion=%@&gameId=%@&type=ios&connection=%@", self.md5OpenUDID, self.md5MACAddress, advertisingIdentifier, [[UIDevice currentDevice] systemVersion], self.machineName, kUnityAdsVersion, self.gameId, self.connectionType];
}

- (void)_backgroundRunLoop:(id)dummy
{
	@autoreleasepool
	{
		NSPort *port = [[NSPort alloc] init];
		[port scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
		
		while([[NSThread currentThread] isCancelled] == NO)
		{
			@autoreleasepool
			{
				[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:3.0]];
			}
		}
	}
}

- (void)_refreshCampaignManager
{
	if ([NSThread isMainThread])
	{
		UALOG_DEBUG(@"Cannot be run on main thread.");
		return;
	}

	self.campaignManager.queryString = self.campaignQueryString;
	[self.campaignManager updateCampaigns];
}

- (void)_startCampaignManager
{
	if ([NSThread isMainThread])
	{
		UALOG_DEBUG(@"Cannot be run on main thread.");
		return;
	}
	
	self.campaignManager = [[UnityAdsCampaignManager alloc] init];
	self.campaignManager.delegate = self;
	[self _refreshCampaignManager];
}

- (void)_startAnalyticsUploader
{
	if ([NSThread isMainThread])
	{
		UALOG_DEBUG(@"Cannot be run on main thread.");
		return;
	}
	
	self.analyticsUploader = [[UnityAdsAnalyticsUploader alloc] init];
	[self.analyticsUploader retryFailedUploads];
}

- (void)_logVideoAnalyticsWithPosition:(VideoAnalyticsPosition)videoPosition campaign:(UnityAdsCampaign *)campaign
{
	if (campaign == nil)
	{
		UALOG_DEBUG(@"Campaign is nil.");
		return;
	}
	
	dispatch_async(self.queue, ^{
		NSString *positionString = nil;
		NSString *trackingString = nil;
		if (videoPosition == kVideoAnalyticsPositionStart)
		{
			positionString = @"video_start";
			trackingString = @"start";
		}
		else if (videoPosition == kVideoAnalyticsPositionFirstQuartile)
			positionString = @"first_quartile";
		else if (videoPosition == kVideoAnalyticsPositionMidPoint)
			positionString = @"mid_point";
		else if (videoPosition == kVideoAnalyticsPositionThirdQuartile)
			positionString = @"third_quartile";
		else if (videoPosition == kVideoAnalyticsPositionEnd)
		{
			positionString = @"video_end";
			trackingString = @"view";
		}
		
		NSString *query = [NSString stringWithFormat:@"applicationId=%@&type=%@&trackingId=%@&providerId=%@", self.gameId, positionString, self.gamerID, campaign.id];
		
		[self.analyticsUploader performSelector:@selector(sendViewReportWithQueryString:) onThread:self.backgroundThread withObject:query waitUntilDone:NO];
		
		if (trackingString != nil)
		{
			NSString *trackingQuery = [NSString stringWithFormat:@"%@/%@/%@?gameId=%@", self.gamerID, trackingString, campaign.id, self.gameId];
			[self.analyticsUploader performSelector:@selector(sendTrackingCallWithQueryString:) onThread:self.backgroundThread withObject:trackingQuery waitUntilDone:NO];
		}
	});
}

- (void)_notifyDelegateOfCampaignAvailability
{
	if (self.campaigns != nil && self.rewardItem != nil && self.webViewInitialized)
	{
		if ([self.delegate respondsToSelector:@selector(unityAdsFetchCompleted:)])
			[self.delegate unityAdsFetchCompleted:self];
	}
}

- (void)_trackInstall
{
	if (self.gameId == nil)
	{
		UALOG_ERROR(@"Unity Ads has not been started properly. Launch with -startWithGameId: first.");
		return;
	}
	
	dispatch_async(self.queue, ^{
		NSString *queryString = [NSString stringWithFormat:@"%@/install", self.gameId];
		NSString *bodyString = [NSString stringWithFormat:@"openUdid=%@&macAddress=%@", self.md5OpenUDID, self.md5MACAddress];
		NSDictionary *queryDictionary = @{ kUnityAdsQueryDictionaryQueryKey : queryString, kUnityAdsQueryDictionaryBodyKey : bodyString };
		
		[self.analyticsUploader performSelector:@selector(sendInstallTrackingCallWithQueryDictionary:) onThread:self.backgroundThread withObject:queryDictionary waitUntilDone:NO];
	});
}

- (void)_refresh
{
	if (self.gameId == nil)
	{
		UALOG_ERROR(@"Unity Ads has not been started properly. Launch with -startWithGameId: first.");
		return;
	}
	
	UALOG_DEBUG(@"");
	
	dispatch_async(self.queue, ^{
		self.connectionType = [self _currentConnectionType];
		self.campaignQueryString = [self _queryString];
		
		[self performSelector:@selector(_refreshCampaignManager) onThread:self.backgroundThread withObject:nil waitUntilDone:NO];
		[self.analyticsUploader performSelector:@selector(retryFailedUploads) onThread:self.backgroundThread withObject:nil waitUntilDone:NO];
	});
}

#pragma mark - Public

- (void)startWithGameId:(NSString *)gameId
{
	if ( ! [NSThread isMainThread])
	{
		UALOG_ERROR(@"Unity Ads must be run on main thread.");
		return;
	}
	
	if (gameId == nil || [gameId length] == 0)
	{
		UALOG_ERROR(@"gameId empty or not set.");
		return;
	}
	
	if (self.gameId != nil)
		return;
	
	self.gameId = gameId;
	self.queue = dispatch_queue_create("com.unity3d.ads", NULL);
	
	dispatch_async(self.queue, ^{
		self.machineName = [self _analyticsMachineName];
		self.md5AdvertisingIdentifier = [self _md5AdvertisingIdentifierString];
		self.md5MACAddress = [self _md5MACAddressString];
		self.md5OpenUDID = [self _md5OpenUDIDString];
		self.connectionType = [self _currentConnectionType];
		self.campaignQueryString = [self _queryString];
		
		self.backgroundThread = [[NSThread alloc] initWithTarget:self selector:@selector(_backgroundRunLoop:) object:nil];
		[self.backgroundThread start];

		[self performSelector:@selector(_startCampaignManager) onThread:self.backgroundThread withObject:nil waitUntilDone:NO];
		[self performSelector:@selector(_startAnalyticsUploader) onThread:self.backgroundThread withObject:nil waitUntilDone:NO];
		
		dispatch_sync(dispatch_get_main_queue(), ^{
			self.viewManager = [[UnityAdsViewManager alloc] init];
			self.viewManager.delegate = self;
			self.viewManager.machineName = self.machineName;
			self.viewManager.md5AdvertisingIdentifier = self.md5AdvertisingIdentifier;
			self.viewManager.md5MACAddress = self.md5MACAddress;
			self.viewManager.md5OpenUDID = self.md5OpenUDID;
			[self.viewManager start];
		});
	});
}

- (UIView *)adsView
{
	if ( ! [NSThread isMainThread])
	{
		UALOG_ERROR(@"Must be run on main thread.");
		return nil;
	}
	
	if ([self.campaigns count] > 0)
	{
		UIView *adView = [self.viewManager adView];
		if (adView != nil)
		{
			if ([self.delegate respondsToSelector:@selector(unityAdsWillShow:)])
				[self.delegate unityAdsWillShow:self];

			return adView;
		}
	}
	
	return nil;
}

- (BOOL)canShow
{
	if ( ! [NSThread isMainThread])
	{
		UALOG_ERROR(@"Must be run on main thread.");
		return NO;
	}

	return ([self.campaigns count] > 0 && self.webViewInitialized);
}

- (void)stopAll
{
	if ( ! [NSThread isMainThread])
	{
		UALOG_ERROR(@"Must be run on main thread.");
		return;
	}
	
	[self.campaignManager performSelector:@selector(cancelAllDownloads) onThread:self.backgroundThread withObject:nil waitUntilDone:NO];
}

- (void)trackInstall
{
	if ( ! [NSThread isMainThread])
	{
		UALOG_ERROR(@"Must be run on main thread.");
		return;
	}
	
	[self _trackInstall];
}

- (void)refresh
{
	if ( ! [NSThread isMainThread])
	{
		UALOG_ERROR(@"Must be run on main thread.");
		return;
	}
	
	[self _refresh];
}

- (void)dealloc
{
	self.campaignManager.delegate = nil;
	self.viewManager.delegate = nil;
}

#pragma mark - UnityAdsCampaignManagerDelegate

- (void)campaignManager:(UnityAdsCampaignManager *)campaignManager updatedWithCampaigns:(NSArray *)campaigns rewardItem:(UnityAdsRewardItem *)rewardItem gamerID:(NSString *)gamerID json:(NSString *)json
{
	if ( ! [NSThread isMainThread])
	{
		UALOG_ERROR(@"Method must be run on main thread.");
		return;
	}

	UALOG_DEBUG(@"");
	
	// If campaigns already exist, it means that campaigns were updated, and we might want to update the webapp.
	if (self.campaigns != nil)
	{
		self.webViewInitialized = NO;
		[self.viewManager start];
	}
	
	self.campaigns = campaigns;
	self.rewardItem = rewardItem;
	self.gamerID = gamerID;
	self.viewManager.campaignJSON = json;
	
	[self _notifyDelegateOfCampaignAvailability];
}

#pragma mark - UnityAdsViewManagerDelegate

-(UnityAdsCampaign *)viewManager:(UnityAdsViewManager *)viewManager campaignWithID:(NSString *)campaignID
{
	UnityAdsCampaign *foundCampaign = nil;
	
	for (UnityAdsCampaign *campaign in self.campaigns)
	{
		if ([campaign.id isEqualToString:campaignID])
		{
			foundCampaign = campaign;
			break;
		}
	}
	
	UALOG_DEBUG(@"");
	
	return foundCampaign;
}

-(NSURL *)viewManager:(UnityAdsViewManager *)viewManager videoURLForCampaign:(UnityAdsCampaign *)campaign
{
	UALOG_DEBUG(@"");
	
	return [self.campaignManager videoURLForCampaign:campaign];
}

- (void)viewManagerStartedPlayingVideo:(UnityAdsViewManager *)viewManager
{
	UALOG_DEBUG(@"");
	
	if ([self.delegate respondsToSelector:@selector(unityAdsVideoStarted:)])
		[self.delegate unityAdsVideoStarted:self];
}

- (void)viewManagerVideoEnded:(UnityAdsViewManager *)viewManager
{
	UALOG_DEBUG(@"");
	
	[self.delegate unityAds:self completedVideoWithRewardItemKey:self.rewardItem.key];
}

- (void)viewManager:(UnityAdsViewManager *)viewManager loggedVideoPosition:(VideoAnalyticsPosition)videoPosition campaign:(UnityAdsCampaign *)campaign
{
	UALOG_DEBUG(@"");
	
	[self _logVideoAnalyticsWithPosition:videoPosition campaign:campaign];
}

- (UIViewController *)viewControllerForPresentingViewControllersForViewManager:(UnityAdsViewManager *)viewManager
{
	UALOG_DEBUG(@"");
	
	return [self.delegate viewControllerForPresentingViewControllersForAds:self];
}

- (void)viewManagerWillCloseAdView:(UnityAdsViewManager *)viewManager
{
	UALOG_DEBUG(@"");
	
	if ([self.delegate respondsToSelector:@selector(unityAdsWillHide:)])
		[self.delegate unityAdsWillHide:self];
}

- (void)viewManagerWebViewInitialized:(UnityAdsViewManager *)viewManager
{
	UALOG_DEBUG(@"");
	
	self.webViewInitialized = YES;
	
	[self _notifyDelegateOfCampaignAvailability];
}

@end

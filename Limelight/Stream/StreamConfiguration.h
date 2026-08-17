//
//  StreamConfiguration.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@interface StreamConfiguration : NSObject

@property NSString* host;
/// The host's own identifier, which does not change when it is reached at a different address.
/// `host` above is whichever address answered discovery first, so it is no use for remembering
/// anything about the machine.
@property NSString* hostUuid;
/// Every address form this host is known by, the one in use first. One machine answers as a LAN
/// address, a Tailscale address, a MagicDNS name and an IPv6 literal, and anything that filed
/// something under one of them needs to find it again under the others.
@property NSArray<NSString *>* hostAddresses;
@property unsigned short httpsPort;
@property NSString* appVersion;
@property NSString* gfeVersion;
@property NSString* appID;
@property NSString* appName;
@property NSString* rtspSessionUrl;
@property int serverCodecModeSupport;
@property int width;
@property int height;
@property int frameRate;
@property int bitRate;
@property int riKeyId;
@property NSData* riKey;
@property int gamepadMask;
@property BOOL optimizeGameSettings;
@property BOOL playAudioOnPC;
@property BOOL swapABXYButtons;
@property int audioConfiguration;
@property int supportedVideoFormats;
@property BOOL multiController;
@property BOOL useFramePacing;
@property NSData* serverCert;

@end

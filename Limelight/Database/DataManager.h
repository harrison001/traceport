//
//  DataManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/28/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "AppDelegate.h"
#import "TemporaryHost.h"
#import "TemporaryApp.h"
#import "TemporarySettings.h"

@interface DataManager : NSObject

- (void) saveSettingsWithBitrate:(NSInteger)bitrate
                       framerate:(NSInteger)framerate
                          height:(NSInteger)height
                           width:(NSInteger)width
                audioConfig:(NSInteger)audioConfig
                onscreenControls:(NSInteger)onscreenControls
                   optimizeGames:(BOOL)optimizeGames
                 multiController:(BOOL)multiController
                 swapABXYButtons:(BOOL)swapABXYButtons
                       audioOnPC:(BOOL)audioOnPC
                  preferredCodec:(uint32_t)preferredCodec
                  useFramePacing:(BOOL)useFramePacing
                       enableHdr:(BOOL)enableHdr
                  btMouseSupport:(BOOL)btMouseSupport
               absoluteTouchMode:(BOOL)absoluteTouchMode
                    statsOverlay:(BOOL)statsOverlay;

- (NSArray*) getHosts;
- (void) updateHost:(TemporaryHost*)host;
- (void) updateAppsForExistingHost:(TemporaryHost *)host;
- (void) removeHost:(TemporaryHost*)host;
- (void) removeApp:(TemporaryApp*)app;

- (TemporarySettings*) getSettings;

/// The global settings with this host's own choices laid over them (see HostProfile).
/// A nil uuid gives the global settings unchanged.
- (TemporarySettings*) getSettingsForHost:(NSString*)uuid;

- (void) updateUniqueId:(NSString*)uniqueId;
- (NSString*) getUniqueId;

@end

/// What a host is, which decides how touch and the key bar behave against it.
/// Sunshine's /serverinfo carries no platform field, so this is the user's to say.
typedef NS_ENUM(NSInteger, TPTargetType) {
    /// Windows or Linux desktop: what Moonlight was built for.
    TPTargetDesktop = 0,
    /// macOS, through our Sunshine fork.
    TPTargetMacOS = 1,
    /// A phone driven through the TracePort gateway (USB/AirPlay picture, Bluetooth input).
    TPTargetPhone = 2,
};

/// Per-host settings. Every setting is global unless a host overrides it: a phone mirrored
/// through the gateway wants touchscreen mode and a modest bitrate, a desktop the opposite,
/// and one global switch made the user flip it every time they changed hosts.
/// Kept by host UUID in the user defaults rather than in Core Data, so no store migration.
@interface HostProfile : NSObject

/// Settings keys a host may override. Values are NSNumber, as TemporarySettings holds them.
+ (NSArray<NSString*>*) overridableKeys;

/// This host's overrides only (key → NSNumber). Empty when it follows the global settings.
+ (NSDictionary<NSString*, NSNumber*>*) overridesForHost:(NSString*)uuid;

/// Sets one override; nil removes it, so the host follows the global setting again.
+ (void) setOverride:(NSNumber*)value forKey:(NSString*)key host:(NSString*)uuid;

/// Drops every override for this host (the target type stays).
+ (void) resetOverridesForHost:(NSString*)uuid;

/// Lays this host's overrides over settings, in place.
+ (void) applyOverridesForHost:(NSString*)uuid toSettings:(TemporarySettings*)settings;

/// The kind of machine this host is. Unset hosts fall back to what the key bar was told
/// before this existed, then to Windows / Linux. (Starting a stream to an unset host that
/// reports a portrait display marks it as a phone.)
+ (TPTargetType) targetTypeForHost:(NSString*)uuid;
+ (BOOL) hasTargetTypeForHost:(NSString*)uuid;
+ (void) setTargetType:(TPTargetType)type forHost:(NSString*)uuid;
+ (NSString*) nameForTargetType:(TPTargetType)type;

/// The host being streamed, for code that reads settings without a stream configuration
/// at hand (gamepad counting). Set when a stream starts, cleared when it ends.
+ (NSString*) activeHost;
+ (void) setActiveHost:(NSString*)uuid;

@end

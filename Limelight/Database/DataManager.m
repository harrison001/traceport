//
//  DataManager.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/28/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "DataManager.h"
#import "TemporaryApp.h"
#import "TemporarySettings.h"

@implementation DataManager {
    NSManagedObjectContext *_managedObjectContext;
    AppDelegate *_appDelegate;
}

- (id) init {
    self = [super init];
    
    // HACK: Avoid calling [UIApplication delegate] off the UI thread to keep
    // Main Thread Checker happy.
    if ([NSThread isMainThread]) {
        _appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
    }
    else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            self->_appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
        });
    }
    
    _managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    [_managedObjectContext setParentContext:[_appDelegate managedObjectContext]];
    
    return self;
}

- (void) updateUniqueId:(NSString*)uniqueId {
    [_managedObjectContext performBlockAndWait:^{
        [self retrieveSettings].uniqueId = uniqueId;
        [self saveData];
    }];
}

- (NSString*) getUniqueId {
    __block NSString *uid;
    
    [_managedObjectContext performBlockAndWait:^{
        uid = [self retrieveSettings].uniqueId;
    }];

    return uid;
}

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
                    statsOverlay:(BOOL)statsOverlay {
    
    [_managedObjectContext performBlockAndWait:^{
        Settings* settingsToSave = [self retrieveSettings];
        settingsToSave.framerate = [NSNumber numberWithInteger:framerate];
        settingsToSave.bitrate = [NSNumber numberWithInteger:bitrate];
        settingsToSave.height = [NSNumber numberWithInteger:height];
        settingsToSave.width = [NSNumber numberWithInteger:width];
        settingsToSave.audioConfig = [NSNumber numberWithInteger:audioConfig];
        settingsToSave.onscreenControls = [NSNumber numberWithInteger:onscreenControls];
        settingsToSave.optimizeGames = optimizeGames;
        settingsToSave.multiController = multiController;
        settingsToSave.swapABXYButtons = swapABXYButtons;
        settingsToSave.playAudioOnPC = audioOnPC;
        settingsToSave.preferredCodec = preferredCodec;
        settingsToSave.useFramePacing = useFramePacing;
        settingsToSave.enableHdr = enableHdr;
        settingsToSave.btMouseSupport = btMouseSupport;
        settingsToSave.absoluteTouchMode = absoluteTouchMode;
        settingsToSave.statsOverlay = statsOverlay;
        
        [self saveData];
    }];
}

- (void) updateHost:(TemporaryHost *)host {
    [_managedObjectContext performBlockAndWait:^{
        // Add a new persistent managed object if one doesn't exist
        Host* parent = [self getHostForTemporaryHost:host withHostRecords:[self fetchRecords:@"Host"]];
        if (parent == nil) {
            NSEntityDescription* entity = [NSEntityDescription entityForName:@"Host" inManagedObjectContext:self->_managedObjectContext];
            parent = [[Host alloc] initWithEntity:entity insertIntoManagedObjectContext:self->_managedObjectContext];
        }
        
        // Push changes from the temp host to the persistent one
        [host propagateChangesToParent:parent];
        
        [self saveData];
    }];
}

- (void) updateAppsForExistingHost:(TemporaryHost *)host {
    [_managedObjectContext performBlockAndWait:^{
        Host* parent = [self getHostForTemporaryHost:host withHostRecords:[self fetchRecords:@"Host"]];
        if (parent == nil) {
            // The host must exist to be updated
            return;
        }
        
        NSMutableSet *applist = [[NSMutableSet alloc] init];
        NSArray *appRecords = [self fetchRecords:@"App"];
        for (TemporaryApp* app in host.appList) {
            // Add a new persistent managed object if one doesn't exist
            App* parentApp = [self getAppForTemporaryApp:app withAppRecords:appRecords];
            if (parentApp == nil) {
                NSEntityDescription* entity = [NSEntityDescription entityForName:@"App" inManagedObjectContext:self->_managedObjectContext];
                parentApp = [[App alloc] initWithEntity:entity insertIntoManagedObjectContext:self->_managedObjectContext];
            }
            
            [app propagateChangesToParent:parentApp withHost:parent];
            
            [applist addObject:parentApp];
        }
        
        parent.appList = applist;
        
        [self saveData];
    }];
}

- (TemporarySettings*) getSettings {
    __block TemporarySettings *tempSettings;
    
    [_managedObjectContext performBlockAndWait:^{
        tempSettings = [[TemporarySettings alloc] initFromSettings:[self retrieveSettings]];
    }];
    
    return tempSettings;
}

- (TemporarySettings*) getSettingsForHost:(NSString*)uuid {
    TemporarySettings* settings = [self getSettings];
    [HostProfile applyOverridesForHost:uuid toSettings:settings];
    return settings;
}

- (Settings*) retrieveSettings {
    NSArray* fetchedRecords = [self fetchRecords:@"Settings"];
    if (fetchedRecords.count == 0) {
        // create a new settings object with the default values
        NSEntityDescription* entity = [NSEntityDescription entityForName:@"Settings" inManagedObjectContext:_managedObjectContext];
        Settings* settings = [[Settings alloc] initWithEntity:entity insertIntoManagedObjectContext:_managedObjectContext];
        
        return settings;
    } else {
        // we should only ever have 1 settings object stored
        return [fetchedRecords objectAtIndex:0];
    }
}

- (void) removeApp:(TemporaryApp*)app {
    [_managedObjectContext performBlockAndWait:^{
        App* managedApp = [self getAppForTemporaryApp:app withAppRecords:[self fetchRecords:@"App"]];
        if (managedApp != nil) {
            [self->_managedObjectContext deleteObject:managedApp];
            [self saveData];
        }
    }];
}

- (void) removeHost:(TemporaryHost*)host {
    [_managedObjectContext performBlockAndWait:^{
        Host* managedHost = [self getHostForTemporaryHost:host withHostRecords:[self fetchRecords:@"Host"]];
        if (managedHost != nil) {
            [self->_managedObjectContext deleteObject:managedHost];
            [self saveData];
        }
    }];
}

- (void) saveData {
    NSError* error;
    if ([_managedObjectContext hasChanges] && ![_managedObjectContext save:&error]) {
        Log(LOG_E, @"Unable to save hosts to database: %@", error);
    }

    [_appDelegate saveContext];
}

- (NSArray*) getHosts {
    __block NSMutableArray *tempHosts = [[NSMutableArray alloc] init];
    
    [_managedObjectContext performBlockAndWait:^{
        NSArray *hosts = [self fetchRecords:@"Host"];
        
        for (Host* host in hosts) {
            [tempHosts addObject:[[TemporaryHost alloc] initFromHost:host]];
        }
    }];
    
    return tempHosts;
}

// Only call from within performBlockAndWait!!!
- (Host*) getHostForTemporaryHost:(TemporaryHost*)tempHost withHostRecords:(NSArray*)hosts {
    for (Host* host in hosts) {
        if ([tempHost.uuid isEqualToString:host.uuid]) {
            return host;
        }
    }
    
    return nil;
}

// Only call from within performBlockAndWait!!!
- (App*) getAppForTemporaryApp:(TemporaryApp*)tempApp withAppRecords:(NSArray*)apps {
    for (App* app in apps) {
        if ([app.id isEqualToString:tempApp.id] &&
            [app.host.uuid isEqualToString:tempApp.host.uuid]) {
            return app;
        }
    }
    
    return nil;
}

- (NSArray*) fetchRecords:(NSString*)entityName {
    NSArray* fetchedRecords;
    
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    NSEntityDescription* entity = [NSEntityDescription entityForName:entityName inManagedObjectContext:_managedObjectContext];
    [fetchRequest setEntity:entity];
    
    NSError* error;
    fetchedRecords = [_managedObjectContext executeFetchRequest:fetchRequest error:&error];
    //TODO: handle errors
    
    return fetchedRecords;
}

@end



static NSString* const kHostProfileKey = @"TracePortHostProfile";
static NSString* const kTargetTypeKey = @"targetType";
static NSString* sActiveHost;

@implementation HostProfile

+ (NSArray<NSString*>*) overridableKeys {
    return @[@"bitrate", @"framerate", @"audioConfig", @"onscreenControls", @"preferredCodec",
             @"useFramePacing", @"multiController", @"swapABXYButtons", @"playAudioOnPC",
             @"optimizeGames", @"enableHdr", @"btMouseSupport", @"absoluteTouchMode", @"statsOverlay"];
}

+ (NSMutableDictionary*) entryForHost:(NSString*)uuid {
    if (uuid.length == 0) {
        return [NSMutableDictionary dictionary];
    }
    NSDictionary* entry = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kHostProfileKey][uuid];
    return [entry isKindOfClass:[NSDictionary class]] ? [entry mutableCopy] : [NSMutableDictionary dictionary];
}

+ (void) storeEntry:(NSDictionary*)entry forHost:(NSString*)uuid {
    if (uuid.length == 0) {
        return;
    }
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary* all = [[defaults dictionaryForKey:kHostProfileKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (entry.count > 0) {
        all[uuid] = entry;
    }
    else {
        [all removeObjectForKey:uuid];
    }
    [defaults setObject:all forKey:kHostProfileKey];
}

+ (NSDictionary<NSString*, NSNumber*>*) overridesForHost:(NSString*)uuid {
    NSMutableDictionary* entry = [self entryForHost:uuid];
    [entry removeObjectForKey:kTargetTypeKey];
    return entry;
}

+ (void) setOverride:(NSNumber*)value forKey:(NSString*)key host:(NSString*)uuid {
    if (![[self overridableKeys] containsObject:key]) {
        return;
    }
    NSMutableDictionary* entry = [self entryForHost:uuid];
    if (value != nil) {
        entry[key] = value;
    }
    else {
        [entry removeObjectForKey:key];
    }
    [self storeEntry:entry forHost:uuid];
}

+ (void) resetOverridesForHost:(NSString*)uuid {
    NSMutableDictionary* entry = [self entryForHost:uuid];
    NSNumber* type = entry[kTargetTypeKey];
    [entry removeAllObjects];
    if (type != nil) {
        entry[kTargetTypeKey] = type;
    }
    [self storeEntry:entry forHost:uuid];
}

+ (void) applyOverridesForHost:(NSString*)uuid toSettings:(TemporarySettings*)settings {
    NSDictionary* overrides = [self overridesForHost:uuid];
    for (NSString* key in overrides) {
        if (![[self overridableKeys] containsObject:key]) {
            continue;
        }
        // KVC unboxes NSNumber into the BOOL and enum properties as well as the NSNumber ones
        [settings setValue:overrides[key] forKey:key];
    }
}

+ (BOOL) hasTargetTypeForHost:(NSString*)uuid {
    return [self entryForHost:uuid][kTargetTypeKey] != nil;
}

+ (TPTargetType) targetTypeForHost:(NSString*)uuid {
    NSNumber* stored = [self entryForHost:uuid][kTargetTypeKey];
    if (stored != nil) {
        return (TPTargetType)stored.integerValue;
    }
    // What the key bar was told before hosts had a type: 0 = macOS, 1 = Windows
    NSNumber* keyBarKind = uuid.length > 0 ? [[NSUserDefaults standardUserDefaults] objectForKey:[@"KeyBarHostKind." stringByAppendingString:uuid]] : nil;
    if (keyBarKind != nil) {
        return keyBarKind.integerValue == 0 ? TPTargetMacOS : TPTargetDesktop;
    }
    return TPTargetDesktop;
}

+ (void) setTargetType:(TPTargetType)type forHost:(NSString*)uuid {
    NSMutableDictionary* entry = [self entryForHost:uuid];
    entry[kTargetTypeKey] = @(type);
    [self storeEntry:entry forHost:uuid];
}

+ (NSString*) nameForTargetType:(TPTargetType)type {
    switch (type) {
        case TPTargetMacOS: return @"macOS";
        case TPTargetPhone: return @"Phone (TracePort gateway)";
        case TPTargetDesktop:
        default: return @"Windows / Linux";
    }
}

+ (NSString*) activeHost {
    return sActiveHost;
}

+ (void) setActiveHost:(NSString*)uuid {
    sActiveHost = [uuid copy];
}

@end

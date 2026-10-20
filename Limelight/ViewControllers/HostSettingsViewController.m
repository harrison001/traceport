//
//  HostSettingsViewController.m
//  Moonlight
//

#import "HostSettingsViewController.h"
#import "DataManager.h"
#import "OnScreenControls.h"

/// One choice in a row's list: what to store, and what to call it.
@interface HostChoice : NSObject
@property (nonatomic) NSNumber *value;
@property (nonatomic, copy) NSString *label;
@end
@implementation HostChoice
+ (instancetype)value:(NSNumber *)value label:(NSString *)label {
    HostChoice *c = [HostChoice new];
    c.value = value;
    c.label = label;
    return c;
}
@end

/// One overridable setting: its settings key, its title, and the values it may take.
@interface HostSettingRow : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<HostChoice *> *choices;
@end
@implementation HostSettingRow
+ (instancetype)key:(NSString *)key title:(NSString *)title choices:(NSArray<HostChoice *> *)choices {
    HostSettingRow *r = [HostSettingRow new];
    r.key = key;
    r.title = title;
    r.choices = choices;
    return r;
}
+ (instancetype)onOff:(NSString *)key title:(NSString *)title {
    return [self key:key title:title choices:@[[HostChoice value:@YES label:@"On"], [HostChoice value:@NO label:@"Off"]]];
}
@end

/// The "This Host Is" rows, top to bottom.
static TPTargetType TargetTypeAtRow(NSInteger row) {
    static const TPTargetType order[] = { TPTargetMacOS, TPTargetDesktop, TPTargetPhone };
    return order[row];
}

typedef NS_ENUM(NSInteger, HostSection) {
    HostSectionType,
    HostSectionInput,
    HostSectionVideo,
    HostSectionOther,
    HostSectionReset,
    HostSectionCount,
};

@implementation HostSettingsViewController {
    NSString *_uuid;
    NSString *_name;
    NSArray<HostSettingRow *> *_inputRows;
    NSArray<HostSettingRow *> *_videoRows;
    NSArray<HostSettingRow *> *_otherRows;
}

- (instancetype)initWithHostUuid:(NSString *)uuid name:(NSString *)name {
    UITableViewStyle style = UITableViewStyleGrouped;
    if (@available(iOS 13.0, *)) {
        style = UITableViewStyleInsetGrouped;
    }
    self = [super initWithStyle:style];
    _uuid = [uuid copy];
    _name = [name copy];
    self.title = name;

    _inputRows = @[
        [HostSettingRow key:@"absoluteTouchMode" title:@"Touch Mode" choices:@[
            [HostChoice value:@YES label:@"Touchscreen"], [HostChoice value:@NO label:@"Trackpad"]]],
        [HostSettingRow key:@"onscreenControls" title:@"On-Screen Controls" choices:@[
            [HostChoice value:@(OnScreenControlsLevelOff) label:@"Off"],
            [HostChoice value:@(OnScreenControlsLevelAuto) label:@"Auto"],
            [HostChoice value:@(OnScreenControlsLevelSimple) label:@"Simple"],
            [HostChoice value:@(OnScreenControlsLevelFull) label:@"Full"]]],
        [HostSettingRow onOff:@"btMouseSupport" title:@"Mouse Support"],
        [HostSettingRow onOff:@"swapABXYButtons" title:@"Swap A/B and X/Y"],
        [HostSettingRow onOff:@"multiController" title:@"Multiple Controllers"],
    ];
    _videoRows = @[
        [HostSettingRow key:@"bitrate" title:@"Bitrate" choices:@[
            [HostChoice value:@2000 label:@"2 Mbps"], [HostChoice value:@5000 label:@"5 Mbps"],
            [HostChoice value:@10000 label:@"10 Mbps"], [HostChoice value:@20000 label:@"20 Mbps"],
            [HostChoice value:@30000 label:@"30 Mbps"], [HostChoice value:@50000 label:@"50 Mbps"],
            [HostChoice value:@80000 label:@"80 Mbps"], [HostChoice value:@150000 label:@"150 Mbps"]]],
        [HostSettingRow key:@"framerate" title:@"Frame Rate" choices:@[
            [HostChoice value:@30 label:@"30 FPS"], [HostChoice value:@60 label:@"60 FPS"],
            [HostChoice value:@90 label:@"90 FPS"], [HostChoice value:@120 label:@"120 FPS"]]],
        [HostSettingRow key:@"preferredCodec" title:@"Video Codec" choices:@[
            [HostChoice value:@0 label:@"Automatic"], [HostChoice value:@1 label:@"H.264"],
            [HostChoice value:@2 label:@"HEVC"], [HostChoice value:@3 label:@"AV1"]]],
        [HostSettingRow onOff:@"enableHdr" title:@"HDR"],
        [HostSettingRow onOff:@"useFramePacing" title:@"Frame Pacing"],
    ];
    _otherRows = @[
        [HostSettingRow onOff:@"playAudioOnPC" title:@"Play Audio on Host"],
        [HostSettingRow onOff:@"optimizeGames" title:@"Optimize Game Settings"],
        [HostSettingRow onOff:@"statsOverlay" title:@"Statistics Overlay"],
    ];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                           target:self
                                                                                           action:@selector(done)];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Data

- (NSArray<HostSettingRow *> *)rowsForSection:(NSInteger)section {
    switch (section) {
        case HostSectionInput: return _inputRows;
        case HostSectionVideo: return _videoRows;
        case HostSectionOther: return _otherRows;
        default: return @[];
    }
}

/// What the global settings say for this key, as the same NSNumber a host would store.
- (NSNumber *)globalValueForKey:(NSString *)key {
    TemporarySettings *global = [[[DataManager alloc] init] getSettings];
    return [global valueForKey:key];
}

- (NSString *)labelForValue:(NSNumber *)value inRow:(HostSettingRow *)row {
    for (HostChoice *c in row.choices) {
        if ([c.value isEqualToNumber:value]) {
            return c.label;
        }
    }
    // A global value not in this list (a custom bitrate, say)
    if ([row.key isEqualToString:@"bitrate"]) {
        return [NSString stringWithFormat:@"%.1f Mbps", value.doubleValue / 1000.0];
    }
    return value.stringValue;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return HostSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case HostSectionType: return 3;
        case HostSectionReset: return 1;
        case HostSectionVideo: return _videoRows.count + 1;   // + stream resolution
        default: return [self rowsForSection:section].count;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case HostSectionType: return @"This Host Is";
        case HostSectionInput: return @"Input";
        case HostSectionVideo: return @"Video";
        case HostSectionOther: return @"Other";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case HostSectionType:
            return @"Decides how touch and the key bar behave on this host.";
        case HostSectionOther:
            return @"\"Global\" means the row follows the app-wide setting; pick a value to give this host its own.";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];

    if (indexPath.section == HostSectionType) {
        TPTargetType type = TargetTypeAtRow(indexPath.row);
        cell.textLabel.text = [HostProfile nameForTargetType:type];
        cell.accessoryType = [HostProfile targetTypeForHost:_uuid] == type ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return cell;
    }
    if (indexPath.section == HostSectionReset) {
        cell.textLabel.text = @"Use Global Settings for Everything";
        if (@available(iOS 13.0, *)) {
            cell.textLabel.textColor = [UIColor systemRedColor];
        }
        return cell;
    }
    if (indexPath.section == HostSectionVideo && indexPath.row == (NSInteger)_videoRows.count) {
        cell.textLabel.text = @"Stream Resolution";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    HostSettingRow *row = [self rowsForSection:indexPath.section][indexPath.row];
    NSNumber *own = [HostProfile overridesForHost:_uuid][row.key];
    cell.textLabel.text = row.title;
    if (own != nil) {
        cell.detailTextLabel.text = [self labelForValue:own inRow:row];
        if (@available(iOS 13.0, *)) {
            cell.detailTextLabel.textColor = [UIColor labelColor];
        }
    }
    else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"Global (%@)", [self labelForValue:[self globalValueForKey:row.key] inRow:row]];
        if (@available(iOS 13.0, *)) {
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == HostSectionType) {
        TPTargetType type = TargetTypeAtRow(indexPath.row);
        [HostProfile setTargetType:type forHost:_uuid];
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:HostSectionType] withRowAnimation:UITableViewRowAnimationNone];
        return;
    }
    if (indexPath.section == HostSectionReset) {
        [HostProfile resetOverridesForHost:_uuid];
        [tableView reloadData];
        return;
    }
    if (indexPath.section == HostSectionVideo && indexPath.row == (NSInteger)_videoRows.count) {
        if (self.chooseResolution != nil) {
            void (^choose)(void) = self.chooseResolution;
            [self dismissViewControllerAnimated:YES completion:^{ choose(); }];
        }
        return;
    }

    HostSettingRow *row = [self rowsForSection:indexPath.section][indexPath.row];
    NSNumber *own = [HostProfile overridesForHost:_uuid][row.key];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:row.title
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *globalLabel = [NSString stringWithFormat:@"Global (%@)", [self labelForValue:[self globalValueForKey:row.key] inRow:row]];
    [sheet addAction:[UIAlertAction actionWithTitle:own == nil ? [@"✓ " stringByAppendingString:globalLabel] : globalLabel
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [HostProfile setOverride:nil forKey:row.key host:self->_uuid];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }]];
    for (HostChoice *choice in row.choices) {
        BOOL chosen = own != nil && [own isEqualToNumber:choice.value];
        [sheet addAction:[UIAlertAction actionWithTitle:chosen ? [@"✓ " stringByAppendingString:choice.label] : choice.label
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            [HostProfile setOverride:choice.value forKey:row.key host:self->_uuid];
            [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: tableView;
    sheet.popoverPresentationController.sourceRect = (cell ?: tableView).bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

@end

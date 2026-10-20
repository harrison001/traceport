//
//  HostSettingsViewController.h
//  Moonlight
//
//  Settings for one host. Every row follows the global setting until it is given a value of
//  its own here, and says which it is doing, so a host that differs is never a surprise.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HostSettingsViewController : UITableViewController

- (instancetype)initWithHostUuid:(NSString *)uuid name:(NSString *)name;

/// Called from the "Stream Resolution" row; the resolution sheet lives with the host list.
@property (nonatomic, copy, nullable) void (^chooseResolution)(void);

@end

NS_ASSUME_NONNULL_END

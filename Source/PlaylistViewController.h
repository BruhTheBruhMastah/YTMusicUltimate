#import <UIKit/UIKit.h>

// Shows a downloaded playlist's tracks in their original order and plays them in that order.
// Present it inside a UINavigationController.
@interface YTMUPlaylistViewController : UITableViewController
- (instancetype)initWithName:(NSString *)name tracks:(NSArray<NSString *> *)tracks startIndex:(NSInteger)startIndex;
@end

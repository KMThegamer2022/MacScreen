#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin wrapper around CoreGraphics' private CGVirtualDisplay API.
/// Creates a real (virtual) monitor that macOS treats as an extra display.
@interface MSVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
+ (nullable MSVirtualDisplay *)createWithName:(NSString *)name
                                       serial:(unsigned int)serial
                                        width:(unsigned int)width
                                       height:(unsigned int)height
                                        hiDPI:(BOOL)hiDPI
                                  refreshRate:(double)refreshRate;
/// Change the display's resolution in place (same display ID, no topology teardown).
- (BOOL)resizeToWidth:(unsigned int)width height:(unsigned int)height hiDPI:(BOOL)hiDPI refreshRate:(double)refreshRate;
@end

NS_ASSUME_NONNULL_END

#import "CVD.h"

// Private CoreGraphics interfaces (resolved at runtime via NSClassFromString).
@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
- (void)setDispatchQueue:(dispatch_queue_t)q;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)w height:(unsigned int)h refreshRate:(double)r;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (retain, nonatomic) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s;
@end

static BOOL MSApplyMode(CGVirtualDisplay *disp, unsigned int width, unsigned int height, BOOL hiDPI, double refreshRate) {
    Class modeC = NSClassFromString(@"CGVirtualDisplayMode");
    Class setC  = NSClassFromString(@"CGVirtualDisplaySettings");
    CGVirtualDisplaySettings *s = [[setC alloc] init];
    s.hiDPI = hiDPI ? 1 : 0;
    NSMutableArray *modes = [NSMutableArray array];
    [modes addObject:[[modeC alloc] initWithWidth:width height:height refreshRate:refreshRate]];
    if (refreshRate > 30.5) {
        [modes addObject:[[modeC alloc] initWithWidth:width height:height refreshRate:30.0]];
    }
    s.modes = modes;
    return [disp applySettings:s];
}

@implementation MSVirtualDisplay {
    id _display;
}

+ (MSVirtualDisplay *)createWithName:(NSString *)name
                              serial:(unsigned int)serial
                               width:(unsigned int)width
                              height:(unsigned int)height
                               hiDPI:(BOOL)hiDPI
                         refreshRate:(double)refreshRate {
    Class descC = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class modeC = NSClassFromString(@"CGVirtualDisplayMode");
    Class setC  = NSClassFromString(@"CGVirtualDisplaySettings");
    Class dispC = NSClassFromString(@"CGVirtualDisplay");
    if (!descC || !modeC || !setC || !dispC) return nil;

    CGVirtualDisplayDescriptor *d = [[descC alloc] init];
    d.name = name;
    d.maxPixelsWide = hiDPI ? 7680 : 3840;
    d.maxPixelsHigh = hiDPI ? 7680 : 3840;
    d.sizeInMillimeters = CGSizeMake(width / 110.0 * 25.4, height / 110.0 * 25.4);
    d.productID = 0x4D53;   // 'MS'
    d.vendorID  = 0x4D41;   // 'MA'
    d.serialNum = serial;
    d.queue = dispatch_get_main_queue();
    d.terminationHandler = ^(id a, id b) {};

    CGVirtualDisplay *disp = [[dispC alloc] initWithDescriptor:d];
    if (!disp) return nil;

    if (!MSApplyMode(disp, width, height, hiDPI, refreshRate)) return nil;
    if (disp.displayID == 0) return nil;

    MSVirtualDisplay *r = [[MSVirtualDisplay alloc] init];
    r->_display = disp;
    return r;
}

- (BOOL)resizeToWidth:(unsigned int)width height:(unsigned int)height hiDPI:(BOOL)hiDPI refreshRate:(double)refreshRate {
    return MSApplyMode((CGVirtualDisplay *)_display, width, height, hiDPI, refreshRate);
}

- (CGDirectDisplayID)displayID {
    return ((CGVirtualDisplay *)_display).displayID;
}

@end

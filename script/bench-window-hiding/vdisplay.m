// Usage: vdisplay [width height]. Adds a virtual display until the process exits; vm-test.sh runs it in the guest
// for a second monitor, because tart gives a macOS guest one display. CGVirtualDisplay is private CoreGraphics API.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain) dispatch_queue_t queue;
@property (retain) NSString *name;
@property unsigned int maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum;
@property CGSize sizeInMillimeters;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property unsigned int hiDPI;
@property (retain) NSArray *modes;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly) CGDirectDisplayID displayID;
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        unsigned int w = argc > 2 ? atoi(argv[1]) : 1280, h = argc > 2 ? atoi(argv[2]) : 800;
        CGVirtualDisplayDescriptor *d = [CGVirtualDisplayDescriptor new];
        d.queue = dispatch_get_main_queue();
        d.name = @"Aero Virtual";
        d.maxPixelsWide = w; d.maxPixelsHigh = h;
        d.sizeInMillimeters = CGSizeMake(w * 0.26, h * 0.26);
        d.vendorID = 0xA3A0; d.productID = 0x0001; d.serialNum = 0x0001;
        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:d];
        if (!display) { fprintf(stderr, "CGVirtualDisplay init failed\n"); return 1; }
        CGVirtualDisplaySettings *s = [CGVirtualDisplaySettings new];
        s.hiDPI = 0;
        s.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:60]];
        if (![display applySettings:s]) { fprintf(stderr, "applySettings failed\n"); return 1; }
        printf("virtual display %u (%ux%u)\n", display.displayID, w, h);
        fflush(stdout);
        dispatch_main();
    }
}

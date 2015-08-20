
#import <Foundation/Foundation.h>
@import AVFoundation;

typedef NS_ENUM(NSInteger, MirrorType)
{
    kMirrorNone = 0,
    kMirrorLeftRightMirror,
    kMirrorUpDownReflection,
    kMirror4Square,
};

@interface CustomVideoCompositor : NSObject<AVVideoCompositing>

@end

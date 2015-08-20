//
//  ExportEffects
//  FunCrop
//
//  Created by Johnny Xu(徐景周) on 5/30/15.
//  Copyright (c) 2015 Future Studio. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

typedef NS_ENUM(NSInteger, TransitionType)
{
    kTransitionTypeNone = 0,
    kTransitionTypePushHorizontalSpinFromRight = 1,
    kTransitionTypePushHorizontalFromRight,
    kTransitionTypePushHorizontalFromLeft,
    kTransitionTypePushVerticalFromBottom,
    kTransitionTypePushVerticalFromTop,
    kTransitionTypeCrossFade,
};

typedef NSString *(^JZOutputFilenameBlock)();
typedef void (^JZFinishVideoBlock)(BOOL success, id result);
typedef void (^JZExportProgressBlock)(NSNumber *percentage);

@interface ExportEffects : NSObject

@property (copy, nonatomic) JZFinishVideoBlock finishVideoBlock;
@property (copy, nonatomic) JZExportProgressBlock exportProgressBlock;
@property (copy, nonatomic) JZOutputFilenameBlock filenameBlock;

+ (ExportEffects *)sharedInstance;

- (void)addEffectToVideo:(NSString *)videoFilePath withAudioFilePath:(NSString *)audioFilePath;
- (void)writeExportedVideoToAssetsLibrary:(NSString *)outputPath;

@end

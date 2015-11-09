//
//  ExportEffects
//  FunCrop
//
//  Created by Johnny Xu(徐景周) on 5/30/15.
//  Copyright (c) 2015 Future Studio. All rights reserved.
//

#import <QuartzCore/QuartzCore.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import "ExportEffects.h"

#define SplitCount 3
#define DefaultOutputVideoName @"outputMovie.mp4"
#define DefaultOutputAudioName @"outputAudio.caf"

@interface ExportEffects ()
{
}

@property (nonatomic, strong) NSTimer *timerEffect;
@property (nonatomic, strong) AVAssetExportSession *exportSession;

@property (nonatomic, strong) NSMutableArray *clips; // array of AVURLAssets
@property (nonatomic, strong) NSMutableArray *clipTimeRanges; // array of CMTimeRanges stored in NSValues.

@property (nonatomic) TransitionType transitionType;
@property (nonatomic) CMTime transitionDuration;

@end

@implementation ExportEffects
{

}

+ (ExportEffects *)sharedInstance
{
    static ExportEffects *sharedInstance = nil;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        sharedInstance = [[ExportEffects alloc] init];
    });
    
    return sharedInstance;
}

- (id)init
{
    self = [super init];
    
    if (self)
    {
        _timerEffect = nil;
        _exportSession = nil;
        _filenameBlock = nil;
        
        _clips = [[NSMutableArray alloc] initWithCapacity:SplitCount];
        _clipTimeRanges = [[NSMutableArray alloc] initWithCapacity:SplitCount];
        
        _transitionType = kTransitionTypeNone;
        _transitionDuration = CMTimeMake(60, 600);
    }
    return self;
}

- (void)dealloc
{
    if (_exportSession)
    {
        _exportSession = nil;
    }
    
    if (_timerEffect)
    {
        [_timerEffect invalidate];
        _timerEffect = nil;
    }
}

#pragma mark Utility methods
- (NSString*)getOutputFilePath
{
    NSString* mp4OutputFile = [NSTemporaryDirectory() stringByAppendingPathComponent:DefaultOutputVideoName];
    return mp4OutputFile;
}

- (NSString*)getTempOutputFilePath
{
    NSString *path = NSTemporaryDirectory();
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateStyle:NSDateFormatterMediumStyle];
    [formatter setTimeStyle:NSDateFormatterShortStyle];
    formatter.dateFormat = @"yyyyMMddHHmmssSSS";
    NSString *nowTimeStr = [formatter stringFromDate:[NSDate dateWithTimeIntervalSinceNow:0]];

    NSString *fileName = [[path stringByAppendingPathComponent:nowTimeStr] stringByAppendingString:@".mov"];
    return fileName;
}

#pragma mark - writeExportedVideoToAssetsLibrary
- (void)writeExportedVideoToAssetsLibrary:(NSString *)outputPath
{
    __unsafe_unretained typeof(self) weakSelf = self;
    NSURL *exportURL = [NSURL fileURLWithPath:outputPath];
    ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
    if ([library videoAtPathIsCompatibleWithSavedPhotosAlbum:exportURL])
    {
        [library writeVideoAtPathToSavedPhotosAlbum:exportURL completionBlock:^(NSURL *assetURL, NSError *error)
         {
             NSString *message;
             if (!error)
             {
                 message = GBLocalizedString(@"MsgSuccess");
             }
             else
             {
                 message = [error description];
             }
             
             NSLog(@"%@", message);
             
             // Output path
             self.filenameBlock = ^(void) {
                 return outputPath;
             };
             
             if (weakSelf.finishVideoBlock)
             {
                 weakSelf.finishVideoBlock(YES, message);
             }
         }];
    }
    else
    {
        NSString *message = GBLocalizedString(@"MsgFailed");;
        NSLog(@"%@", message);
        
        // Output path
        self.filenameBlock = ^(void) {
            return @"";
        };
        
        if (_finishVideoBlock)
        {
            _finishVideoBlock(NO, message);
        }
    }
    
    library = nil;
}

#pragma mark - Asset
- (void)synchronizeClipsWithOurClips
{
    NSMutableArray *validClips = [NSMutableArray arrayWithCapacity:SplitCount];
    for (AVURLAsset *asset in self.clips)
    {
        if (![asset isKindOfClass:[NSNull class]])
        {
            [validClips addObject:asset];
        }
    }
    
    self.clips = validClips;
}

- (void)synchronizeClipTimeRangesWithOurClipTimeRanges
{
    NSMutableArray *validClipTimeRanges = [NSMutableArray arrayWithCapacity:SplitCount];
    for (NSValue *timeRange in self.clipTimeRanges)
    {
        if (! [timeRange isKindOfClass:[NSNull class]])
        {
            [validClipTimeRanges addObject:timeRange];
        }
    }
    
    self.clipTimeRanges = validClipTimeRanges;
}

- (void)buildTransitionComposition:(AVMutableComposition *)composition withVideoComposition:(AVMutableVideoComposition *)videoComposition withAudio:(BOOL)useAudio
{
    CMTime nextClipStartTime = kCMTimeZero;
    NSInteger i;
    
    // Make transitionDuration no greater than half the shortest clip duration.
    CMTime transitionDuration = self.transitionDuration;
    for (i = 0; i < [_clips count]; i++ )
    {
        NSValue *clipTimeRange = [_clipTimeRanges objectAtIndex:i];
        if (clipTimeRange)
        {
            CMTime halfClipDuration = [clipTimeRange CMTimeRangeValue].duration;
            halfClipDuration.timescale *= 2; // You can halve a rational by doubling its denominator.
            transitionDuration = CMTimeMinimum(transitionDuration, halfClipDuration);
        }
    }
    
    // Add two video tracks and two audio tracks.
    AVMutableCompositionTrack *compositionVideoTracks[SplitCount];
    AVMutableCompositionTrack *compositionAudioTracks[SplitCount];
    for (int i = 0; i < SplitCount; ++i)
    {
        compositionVideoTracks[i] = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
        compositionAudioTracks[i] = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    }
    
    CMTimeRange *passThroughTimeRanges = alloca(sizeof(CMTimeRange) * [_clips count]);
    CMTimeRange *transitionTimeRanges = alloca(sizeof(CMTimeRange) * [_clips count]);
    
    // Place clips into alternating video & audio tracks in composition, overlapped by transitionDuration.
    for (i = 0; i < [_clips count]; i++ )
    {
        AVURLAsset *asset = [_clips objectAtIndex:i];
        NSValue *clipTimeRange = [_clipTimeRanges objectAtIndex:i];
        CMTimeRange timeRangeInAsset;
        if (clipTimeRange)
            timeRangeInAsset = [clipTimeRange CMTimeRangeValue];
        else
            timeRangeInAsset = CMTimeRangeMake(kCMTimeZero, [asset duration]);
        
        AVAssetTrack *clipVideoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
        [compositionVideoTracks[i] insertTimeRange:timeRangeInAsset ofTrack:clipVideoTrack atTime:nextClipStartTime error:nil];
        
        if (useAudio)
        {
            if ([[asset tracksWithMediaType:AVMediaTypeAudio] count] != 0)
            {
                AVAssetTrack *clipAudioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] objectAtIndex:0];
                [compositionAudioTracks[i] insertTimeRange:timeRangeInAsset ofTrack:clipAudioTrack atTime:nextClipStartTime error:nil];
            }
        }
        
        passThroughTimeRanges[i] = CMTimeRangeMake(nextClipStartTime, timeRangeInAsset.duration);
        if (i > 0)
        {
            passThroughTimeRanges[i].start = CMTimeAdd(passThroughTimeRanges[i].start, transitionDuration);
            passThroughTimeRanges[i].duration = CMTimeSubtract(passThroughTimeRanges[i].duration, transitionDuration);
        }
        if (i+1 < [_clips count])
        {
            passThroughTimeRanges[i].duration = CMTimeSubtract(passThroughTimeRanges[i].duration, transitionDuration);
        }
        
        // (Note: this arithmetic falls apart if timeRangeInAsset.duration < 2 * transitionDuration.)
        nextClipStartTime = CMTimeAdd(nextClipStartTime, timeRangeInAsset.duration);
        nextClipStartTime = CMTimeSubtract(nextClipStartTime, transitionDuration);
        
        // Remember the time range for the transition to the next item.
        transitionTimeRanges[i] = CMTimeRangeMake(nextClipStartTime, transitionDuration);
    }
    
    NSMutableArray *instructions = [NSMutableArray array];
    for (i = 0; i < [_clips count]; i++ )
    {
        // Pass through clip i.
        AVMutableVideoCompositionInstruction *passThroughInstruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
        passThroughInstruction.timeRange = passThroughTimeRanges[i];
        
        AVMutableVideoCompositionLayerInstruction *passThroughLayer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:compositionVideoTracks[i]];
        
        passThroughInstruction.layerInstructions = [NSArray arrayWithObject:passThroughLayer];
        [instructions addObject:passThroughInstruction];
        
        if (i+1 < [_clips count])
        {
            // Add transition from clip i to clip i+1.
            AVMutableVideoCompositionInstruction *transitionInstruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
            transitionInstruction.timeRange = transitionTimeRanges[i];
            
            AVMutableVideoCompositionLayerInstruction *fromLayer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:compositionVideoTracks[i]];
            AVMutableVideoCompositionLayerInstruction *toLayer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:compositionVideoTracks[i+1]];
            
            switch (self.transitionType)
            {
                case kTransitionTypeCrossFade:
                {
                    // Fade out the fromLayer by setting a ramp from 1.0 to 0.0.
                    [fromLayer setOpacityRampFromStartOpacity:1.0 toEndOpacity:0.0 timeRange:transitionTimeRanges[i]];
                    break;
                }
                case kTransitionTypePushHorizontalSpinFromRight:
                {
                    CGAffineTransform scaleT = CGAffineTransformMakeScale(0.1, 0.1);
                    CGAffineTransform rotateT = CGAffineTransformMakeRotation(M_PI);
                    CGAffineTransform transform = CGAffineTransformTranslate(CGAffineTransformConcat(scaleT, rotateT), 1, 1);
                    [fromLayer setTransformRampFromStartTransform:CGAffineTransformIdentity toEndTransform:transform timeRange:transitionTimeRanges[i]];
                    
                    break;
                }
                case kTransitionTypePushHorizontalFromRight:
                {
                    [fromLayer setTransformRampFromStartTransform:CGAffineTransformIdentity toEndTransform:CGAffineTransformMakeTranslation(-composition.naturalSize.width, 0.0) timeRange:transitionTimeRanges[i]];
                    
                    [toLayer setTransformRampFromStartTransform:CGAffineTransformMakeTranslation(composition.naturalSize.width, 0.0) toEndTransform:CGAffineTransformIdentity timeRange:transitionTimeRanges[i]];
                    
                    break;
                }
                case kTransitionTypePushHorizontalFromLeft:
                {
                    [fromLayer setTransformRampFromStartTransform:CGAffineTransformIdentity toEndTransform:CGAffineTransformMakeTranslation(composition.naturalSize.width, 0.0) timeRange:transitionTimeRanges[i]];
                    
                    [toLayer setTransformRampFromStartTransform:CGAffineTransformMakeTranslation(-composition.naturalSize.width, 0.0) toEndTransform:CGAffineTransformIdentity timeRange:transitionTimeRanges[i]];
                    
                    break;
                }
                case kTransitionTypePushVerticalFromBottom:
                {
                    [fromLayer setTransformRampFromStartTransform:CGAffineTransformIdentity toEndTransform:CGAffineTransformMakeTranslation(0, -composition.naturalSize.height) timeRange:transitionTimeRanges[i]];
                    
                    [toLayer setTransformRampFromStartTransform:CGAffineTransformMakeTranslation(0, +composition.naturalSize.height) toEndTransform:CGAffineTransformIdentity timeRange:transitionTimeRanges[i]];
                    
                    break;
                }
                case kTransitionTypePushVerticalFromTop:
                {
                    [fromLayer setTransformRampFromStartTransform:CGAffineTransformIdentity toEndTransform:CGAffineTransformMakeTranslation(0, composition.naturalSize.height) timeRange:transitionTimeRanges[i]];
                    
                    [toLayer setTransformRampFromStartTransform:CGAffineTransformMakeTranslation(0, -composition.naturalSize.height) toEndTransform:CGAffineTransformIdentity timeRange:transitionTimeRanges[i]];
                    
                    break;
                }
                default:
                    break;
            }
            
            transitionInstruction.layerInstructions = [NSArray arrayWithObjects:fromLayer, toLayer, nil];
            [instructions addObject:transitionInstruction];
        }
    }
    
    videoComposition.instructions = instructions;
}

- (void)addAudioMixToComposition:(AVMutableComposition *)composition withAudioMix:(AVMutableAudioMix *)audioMix withAsset:(AVURLAsset*)commentary
{
    NSInteger i;
    NSArray *tracksToDuck = [composition tracksWithMediaType:AVMediaTypeAudio];
    
    // 1. Clip commentary duration to composition duration.
    CMTimeRange commentaryTimeRange = CMTimeRangeMake(kCMTimeZero, commentary.duration);
    if (CMTIME_COMPARE_INLINE(CMTimeRangeGetEnd(commentaryTimeRange), >, [composition duration]))
        commentaryTimeRange.duration = CMTimeSubtract([composition duration], commentaryTimeRange.start);
    
    // 2. Add the commentary track.
    AVMutableCompositionTrack *compositionCommentaryTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    AVAssetTrack * commentaryTrack = [[commentary tracksWithMediaType:AVMediaTypeAudio] objectAtIndex:0];
    [compositionCommentaryTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, commentaryTimeRange.duration) ofTrack:commentaryTrack atTime:commentaryTimeRange.start error:nil];
    
    // 3. Fade in for bgMusic
    CMTime fadeTime = CMTimeMake(1, 1);
    CMTimeRange startRange = CMTimeRangeMake(kCMTimeZero, fadeTime);
    NSMutableArray *trackMixArray = [NSMutableArray array];
    AVMutableAudioMixInputParameters *trackMixComentray = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:commentaryTrack];
    [trackMixComentray setVolumeRampFromStartVolume:0.0f toEndVolume:0.5f timeRange:startRange];
    [trackMixArray addObject:trackMixComentray];
    
    // 4. Fade in & Fade out for original voices
    for (i = 0; i < [tracksToDuck count]; i++)
    {
        CMTimeRange timeRange = [[tracksToDuck objectAtIndex:i] timeRange];
        if (CMTIME_COMPARE_INLINE(CMTimeRangeGetEnd(timeRange), ==, kCMTimeInvalid))
        {
            break;
        }
        
        CMTime halfSecond = CMTimeMake(1, 2);
        CMTime startTime = CMTimeSubtract(timeRange.start, halfSecond);
        CMTime endRangeStartTime = CMTimeAdd(timeRange.start, timeRange.duration);
        CMTimeRange endRange = CMTimeRangeMake(endRangeStartTime, halfSecond);
        if (startTime.value < 0)
        {
            startTime.value = 0;
        }
        
        [trackMixComentray setVolumeRampFromStartVolume:0.5f toEndVolume:0.2f timeRange:CMTimeRangeMake(startTime, halfSecond)];
        [trackMixComentray setVolumeRampFromStartVolume:0.2f toEndVolume:0.5f timeRange:endRange];
        [trackMixArray addObject:trackMixComentray];
    }
    
    audioMix.inputParameters = trackMixArray;
}

- (void)loadAsset:(AVAsset *)asset withKeys:(NSArray *)assetKeysToLoad usingDispatchGroup:(dispatch_group_t)dispatchGroup
{
    dispatch_group_enter(dispatchGroup);
    [asset loadValuesAsynchronouslyForKeys:assetKeysToLoad completionHandler:^(){
        for (NSString *key in assetKeysToLoad)
        {
            NSError *error;
            if ([asset statusOfValueForKey:key error:&error] == AVKeyValueStatusFailed)
            {
                NSLog(@"Key value loading failed for key:%@ with error: %@", key, error);
                self.filenameBlock = ^(void) {
                    return @"";
                };
                
                if (self.finishVideoBlock)
                {
                    self.finishVideoBlock(NO, GBLocalizedString(@"MsgConvertFailed"));
                }
                
                goto bail;
            }
        }
        
        if (![asset isComposable])
        {
            NSLog(@"Asset is not composable");
            self.filenameBlock = ^(void) {
                return @"";
            };
            
            if (self.finishVideoBlock)
            {
                self.finishVideoBlock(NO, GBLocalizedString(@"MsgConvertFailed"));
            }
            
            goto bail;
        }
        
        [_clips addObject:asset];
        [_clipTimeRanges addObject:[NSValue valueWithCMTimeRange:CMTimeRangeMake(kCMTimeZero, [asset duration])]];
        
    bail:
        {
            dispatch_group_leave(dispatchGroup);
        }
    }];
}

- (void)synchronizeMergeVideo:(TransitionType)transitionType withAudioFilePath:audioFilePath
{
    if ( (_clips == nil) || [_clips count] < 1 )
    {
        NSLog(@"_clips is empty.");
        return;
    }

    // Clips
    [self synchronizeClipsWithOurClips];
    [self synchronizeClipTimeRangesWithOurClipTimeRanges];
    
    CGFloat seconds = 1;
    self.transitionDuration = CMTimeMakeWithSeconds(seconds, 600);
    self.transitionType = transitionType;
    
    CGSize videoSize = [[_clips objectAtIndex:0] naturalSize];
    AVMutableComposition *composition = [AVMutableComposition composition];
    AVMutableVideoComposition *videoComposition = nil;
    
    composition.naturalSize = videoSize;
    videoComposition = [AVMutableVideoComposition videoComposition];
    
    BOOL useAudio = YES;
    if (!isStringEmpty(audioFilePath))
    {
        useAudio = NO;
    }
    
    [self buildTransitionComposition:composition withVideoComposition:videoComposition withAudio:useAudio];
    
    if (videoComposition)
    {
//        videoComposition.frameDuration = CMTimeMake(1, 30); // 30 fps
        AVAssetTrack *clipVideoTrack = [[[_clips objectAtIndex:0] tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
        videoComposition.frameDuration = CMTimeMakeWithSeconds(1.0 / clipVideoTrack.nominalFrameRate, clipVideoTrack.naturalTimeScale);
        videoComposition.renderSize = videoSize;
    }
    
    // Music effect
    AVMutableAudioMix *audioMix = nil;
    if (!isStringEmpty(audioFilePath))
    {
        NSURL *bgMusicURL = getFileURL(audioFilePath);
        AVURLAsset *assetMusic = [[AVURLAsset alloc] initWithURL:bgMusicURL options:nil];
        
        audioMix = [AVMutableAudioMix audioMix];
        [self addAudioMixToComposition:composition withAudioMix:audioMix withAsset:assetMusic];
    }
    
    // Export
    NSString *exportPath = [self getOutputFilePath];
    NSURL *exportURL = [NSURL fileURLWithPath:[self returnFormatString:exportPath]];
    // Delete old file
    unlink([exportPath UTF8String]);
    
    _exportSession = [AVAssetExportSession exportSessionWithAsset:composition presetName:AVAssetExportPresetMediumQuality];
    _exportSession.outputURL = exportURL;
    _exportSession.outputFileType = AVFileTypeMPEG4;
    _exportSession.shouldOptimizeForNetworkUse = YES;
    if (videoComposition)
    {
        _exportSession.videoComposition = videoComposition;
    }
    
    if (audioMix)
    {
        _exportSession.audioMix = audioMix;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        // Progress monitor
        _timerEffect = [NSTimer scheduledTimerWithTimeInterval:0.3f
                                                        target:self
                                                      selector:@selector(retrievingExportProgress)
                                                      userInfo:nil
                                                       repeats:YES];
    });
    
    __block typeof(self) blockSelf = self;
    [_exportSession exportAsynchronouslyWithCompletionHandler:^(void) {
        switch ([_exportSession status])
        {
            case AVAssetExportSessionStatusCompleted:
            {
                // Close timer
                [blockSelf.timerEffect invalidate];
                blockSelf.timerEffect = nil;
                
                // Save video to Album
                [self writeExportedVideoToAssetsLibrary:exportPath];
                
                NSLog(@"Export Successful: %@", exportPath);
                break;
            }
                
            case AVAssetExportSessionStatusFailed:
            {
                // Close timer
                [blockSelf.timerEffect invalidate];
                blockSelf.timerEffect = nil;
                
                // Output path
                self.filenameBlock = ^(void) {
                    return @"";
                };
                
                if (self.finishVideoBlock)
                {
                    self.finishVideoBlock(NO, GBLocalizedString(@"MsgConvertFailed"));
                }
                
                NSLog(@"Export failed: %@, %@", [[blockSelf.exportSession error] localizedDescription], [blockSelf.exportSession error]);
                break;
            }
                
            case AVAssetExportSessionStatusCancelled:
            {
                NSLog(@"Canceled: %@", blockSelf.exportSession.error);
                break;
            }
            default:
                break;
        }
    }];
}

#pragma mark - Export Video
- (void)addEffectToVideo:(NSString *)videoFilePath withAudioFilePath:(NSString *)audioFilePath
{
    if (isStringEmpty(videoFilePath))
    {
        NSLog(@"videoFilePath is empty!");

        // Output path
        self.filenameBlock = ^(void) {
            return @"";
        };
        
        if (self.finishVideoBlock)
        {
            self.finishVideoBlock(NO, GBLocalizedString(@"MsgConvertFailed"));
        }

        return;
    }
    
    CGFloat duration = 0;
    NSURL *videoURL = getFileURL(videoFilePath);
    AVAsset *videoAsset = [AVAsset assetWithURL:videoURL];
    if (videoAsset)
    {
        // Max duration
        duration = CMTimeGetSeconds(videoAsset.duration);
    }
    else
    {
        NSLog(@"videoAsset is empty!");
        
        // Output path
        self.filenameBlock = ^(void) {
            return @"";
        };
        
        if (self.finishVideoBlock)
        {
            self.finishVideoBlock(NO, GBLocalizedString(@"MsgConvertFailed"));
        }
        
        return;
    }

    UIInterfaceOrientation videoOrientation = orientationForTrack(videoAsset);
    NSLog(@"videoOrientation: %ld", (long)videoOrientation);
    if (videoOrientation == UIInterfaceOrientationPortrait)
    {
        // Right rotation 90 degree
        [self setShouldRightRotate90:YES withTrackID:kCMPersistentTrackID_Invalid];
    }
    else
    {
        [self setShouldRightRotate90:NO withTrackID:kCMPersistentTrackID_Invalid];
    }
    
    AVAssetTrack *firstVideoTrack = [[videoAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    CGSize videoSize = CGSizeMake(firstVideoTrack.naturalSize.width, firstVideoTrack.naturalSize.height);
    if (videoSize.width < 10 || videoSize.height < 10)
    {
        NSLog(@"videoSize is empty!");
        
        // Output path
        self.filenameBlock = ^(void) {
            return @"";
        };
        
        if (self.finishVideoBlock)
        {
            self.finishVideoBlock(NO, GBLocalizedString(@"MsgConvertFailed"));
        }
        
        return;
    }
    
    // Clear
    if (_clips && [_clips count] > 0)
    {
        [_clips removeAllObjects];
        _clips = nil;
    }
    _clips = [[NSMutableArray alloc] initWithCapacity:SplitCount];
    
    if (_clipTimeRanges && [_clipTimeRanges count] > 0)
    {
        [_clipTimeRanges removeAllObjects];
        _clipTimeRanges = nil;
    }
    _clipTimeRanges = [[NSMutableArray alloc] initWithCapacity:SplitCount];
    
    dispatch_queue_t serialQueue = dispatch_queue_create("serialQueue", DISPATCH_QUEUE_SERIAL);
    CGFloat durationStep = CMTimeGetSeconds(videoAsset.duration) / SplitCount;
    CGFloat regionStep = 1.0;
    __block CGRect cropRect = CGRectMake(0, 0, videoSize.width, videoSize.height);
    BOOL shouldCrop = [self shouldVideoCrop];
    if (videoSize.width < videoSize.height)
    {
        regionStep = videoSize.height / SplitCount;
        for (int i = 0; i < SplitCount; ++i)
        {
            dispatch_async(serialQueue, ^{
                
                if (shouldCrop)
                {
                    cropRect = CGRectMake(0, i*regionStep, videoSize.width, regionStep);
                }
                
                [self exportTrimmedVideo:videoAsset startTime:i*durationStep stopTime:i*durationStep+durationStep cropRegion:cropRect finishBlock:^(BOOL success, id result) {
                    
                    if (success)
                    {
                        NSLog(@"Export Successful (videoSize.width < videoSize.height): %@", result);
                        
                        AVURLAsset *asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:result]];
                        dispatch_group_t dispatchGroup = dispatch_group_create();
                        NSArray *assetKeysToLoad = @[@"tracks", @"duration", @"composable"];
                        [self loadAsset:asset withKeys:assetKeysToLoad usingDispatchGroup:dispatchGroup];
                        // Wait until both assets are loaded
                        dispatch_group_notify(dispatchGroup, dispatch_get_main_queue(), ^(){
                            
                            if ([_clips count] == SplitCount)
                            {
                                [self synchronizeMergeVideo:[self getTranstionAnimationType] withAudioFilePath:audioFilePath];
                            }
                        });
                    }
                    else
                    {
                        // Output path
                        self.filenameBlock = ^(void) {
                            return @"";
                        };
                        
                        if (self.finishVideoBlock)
                        {
                            self.finishVideoBlock(NO, GBLocalizedString(@"MsgConvertFailed"));
                        }
                    }
                }];
            });
        }
    }
    else
    {
        regionStep = videoSize.width / SplitCount;
        for (int i = 0; i < SplitCount; ++i)
        {
            dispatch_async(serialQueue, ^{
                
                if (shouldCrop)
                {
                    cropRect = CGRectMake(i*regionStep, 0, regionStep, videoSize.height);
                }
                
                [self exportTrimmedVideo:videoAsset startTime:i*durationStep stopTime:i*durationStep+durationStep cropRegion:cropRect finishBlock:^(BOOL success, id result) {
                    
                    if (success)
                    {
                        NSLog(@"Export Successful (videoSize.width > videoSize.height): %@", result);
                        
                        AVURLAsset *asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:result]];
                        dispatch_group_t dispatchGroup = dispatch_group_create();
                        NSArray *assetKeysToLoad = @[@"tracks", @"duration", @"composable"];
                        [self loadAsset:asset withKeys:assetKeysToLoad usingDispatchGroup:dispatchGroup];
                        // Wait until both assets are loaded
                        dispatch_group_notify(dispatchGroup, dispatch_get_main_queue(), ^(){
                            
                            if ([_clips count] == SplitCount)
                            {
                                [self synchronizeMergeVideo:(arc4random()%kTransitionTypePushVerticalFromTop) + kTransitionTypePushHorizontalSpinFromRight withAudioFilePath:audioFilePath];
                            }
                        });
                    }
                    else
                    {
                        // Output path
                        self.filenameBlock = ^(void) {
                            return @"";
                        };
                        
                        if (self.finishVideoBlock)
                        {
                            self.finishVideoBlock(NO, GBLocalizedString(@"MsgConvertFailed"));
                        }
                    }
                }];
            });
        }
    }
}

- (UIImageOrientation)getVideoOrientationFromAsset:(AVAsset *)asset
{
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
    CGSize size = [videoTrack naturalSize];
    CGAffineTransform txf = [videoTrack preferredTransform];
    
    if (size.width == txf.tx && size.height == txf.ty)
        return UIImageOrientationLeft; //return UIInterfaceOrientationLandscapeLeft;
    else if (txf.tx == 0 && txf.ty == 0)
        return UIImageOrientationRight; //return UIInterfaceOrientationLandscapeRight;
    else if (txf.tx == 0 && txf.ty == size.width)
        return UIImageOrientationDown; //return UIInterfaceOrientationPortraitUpsideDown;
    else
        return UIImageOrientationUp;  //return UIInterfaceOrientationPortrait;
}

- (void)exportTrimmedVideo:(AVAsset *)asset startTime:(CGFloat)startTime stopTime:(CGFloat)stopTime cropRegion:(CGRect)cropRect finishBlock:(GenericCallback)finishBlock
{
    if (!asset)
    {
        NSLog(@"asset is empty.");
        
        if (finishBlock)
        {
            finishBlock(NO, GBLocalizedString(@"MsgConvertFailed"));
        }
    }
    
    CMTime start = CMTimeMakeWithSeconds(startTime, asset.duration.timescale);
    CMTime duration = CMTimeMakeWithSeconds(stopTime - startTime, asset.duration.timescale);
    CMTimeRange range = CMTimeRangeMake(start, duration);
    
    AVMutableComposition *composition = [AVMutableComposition composition];
    AVMutableCompositionTrack *videoCompositionTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    AVAssetTrack *assetVideoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    [videoCompositionTrack insertTimeRange:range ofTrack:assetVideoTrack atTime:kCMTimeZero error:nil];
    [videoCompositionTrack setPreferredTransform:assetVideoTrack.preferredTransform];
    
    AVMutableCompositionTrack *audioCompositionTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    if ([[asset tracksWithMediaType:AVMediaTypeAudio] count] > 0)
    {
        AVAssetTrack *assetAudioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] objectAtIndex:0];
        [audioCompositionTrack insertTimeRange:range ofTrack:assetAudioTrack atTime:kCMTimeZero error:nil];
    }
    else
    {
        NSLog(@"Reminder: video hasn't audio!");
    }
    
    AVMutableVideoComposition* videoComposition = [AVMutableVideoComposition videoComposition];
    videoComposition.frameDuration = CMTimeMakeWithSeconds(1.0 / assetVideoTrack.nominalFrameRate, assetVideoTrack.naturalTimeScale);
    videoComposition.renderSize =  cropRect.size; //CGSizeMake(assetVideoTrack.naturalSize.height, assetVideoTrack.naturalSize.height);
    
    AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);
    
    AVMutableVideoCompositionLayerInstruction *layerInstruction = [AVMutableVideoCompositionLayerInstruction
                                                                   videoCompositionLayerInstructionWithAssetTrack:videoCompositionTrack];

    // Fix orientation & Crop
    CGFloat cropOffX = cropRect.origin.x;
    CGFloat cropOffY = cropRect.origin.y;
    UIImageOrientation videoOrientation = [self getVideoOrientationFromAsset:asset];
    
    CGSize videoSize = assetVideoTrack.naturalSize;
    CGAffineTransform t1 = CGAffineTransformIdentity;
    CGAffineTransform t2 = CGAffineTransformIdentity;
    switch (videoOrientation)
    {
        case UIImageOrientationUp:
        {
            videoComposition.renderSize =  CGSizeMake(cropRect.size.height, cropRect.size.width);
            
//            t1 = CGAffineTransformMakeTranslation(assetVideoTrack.naturalSize.height - cropOffX, 0 - cropOffY);
            t1 = CGAffineTransformMakeTranslation(videoSize.height, 0);
            t2 = CGAffineTransformRotate(t1, M_PI_2);
            
            break;
        }
        case UIImageOrientationDown:
        {
            t1 = CGAffineTransformMakeTranslation(0 - cropOffX, videoSize.width - cropOffY); // not fixed width is the real height in upside down
            t2 = CGAffineTransformRotate(t1, - M_PI_2);
            break;
        }
        case UIImageOrientationRight:
        {
            t1 = CGAffineTransformMakeTranslation(0 - cropOffX, 0 - cropOffY);
            t2 = CGAffineTransformRotate(t1, 0);
            break;
        }
        case UIImageOrientationLeft:
        {
            t1 = CGAffineTransformMakeTranslation(videoSize.width - cropOffX, videoSize.height - cropOffY);
            t2 = CGAffineTransformRotate(t1, M_PI);
            break;
        }
        default:
        {
            NSLog(@"no supported orientation has been found in this video");
            break;
        }
    }
    
    CGAffineTransform finalTransform = t2;
    [layerInstruction setTransform:finalTransform atTime:kCMTimeZero];
    
    instruction.layerInstructions = [NSArray arrayWithObject:layerInstruction];
    videoComposition.instructions = [NSArray arrayWithObject: instruction];

    NSString *exportPath = [self getTempOutputFilePath];
    unlink([exportPath UTF8String]);
    NSURL *exportUrl = [NSURL fileURLWithPath:exportPath];
    
    AVAssetExportSession *exportSession = [AVAssetExportSession exportSessionWithAsset:composition presetName:AVAssetExportPresetMediumQuality];
    exportSession.outputURL = exportUrl;
    exportSession.outputFileType = AVFileTypeQuickTimeMovie;
    
    if (videoComposition)
    {
        exportSession.videoComposition = videoComposition;
    }
    
    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        
        switch ([exportSession status])
        {
            case AVAssetExportSessionStatusCompleted:
            {
                if (finishBlock)
                {
                    finishBlock(YES, exportPath);
                }
                
                NSLog(@"Export Successful.");
                
                break;
            }
            case AVAssetExportSessionStatusFailed:
            {
                if (finishBlock)
                {
                    finishBlock(NO, GBLocalizedString(@"MsgConvertFailed"));
                }
                
                NSLog(@"Export failed: %@", [[exportSession error] localizedDescription]);
                break;
            }
            case AVAssetExportSessionStatusCancelled:
            {
                NSLog(@"Export canceled");
                break;
            }
            default:
            {
                NSLog(@"NONE");
                break;
            }
        }
    }];
}

- (AVMutableVideoCompositionLayerInstruction *)layerInstructionAfterFixingOrientationForAsset:(AVAsset *)inAsset
                                                                                     forTrack:(AVMutableCompositionTrack *)inTrack
                                                                                       atTime:(CMTime)inTime
{
    //FIXING ORIENTATION//
    AVMutableVideoCompositionLayerInstruction *videolayerInstruction = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:inTrack];
    AVAssetTrack *videoAssetTrack = [[inAsset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
    UIImageOrientation videoAssetOrientation_  = UIImageOrientationUp;
    BOOL  isVideoAssetPortrait_  = NO;
    CGAffineTransform videoTransform = videoAssetTrack.preferredTransform;
    
    if(videoTransform.a == 0 && videoTransform.b == 1.0 && videoTransform.c == -1.0 && videoTransform.d == 0)
    {
        videoAssetOrientation_= UIImageOrientationRight;
        isVideoAssetPortrait_ = YES;
    }
    if(videoTransform.a == 0 && videoTransform.b == -1.0 && videoTransform.c == 1.0 && videoTransform.d == 0)
    {
        videoAssetOrientation_ =  UIImageOrientationLeft;
        isVideoAssetPortrait_ = YES;
    }
    if(videoTransform.a == 1.0 && videoTransform.b == 0 && videoTransform.c == 0 && videoTransform.d == 1.0)
    {
        videoAssetOrientation_ =  UIImageOrientationUp;
    }
    if(videoTransform.a == -1.0 && videoTransform.b == 0 && videoTransform.c == 0 && videoTransform.d == -1.0)
    {
        videoAssetOrientation_ = UIImageOrientationDown;
    }
    
    CGFloat FirstAssetScaleToFitRatio = 320.0 / videoAssetTrack.naturalSize.width;
    if(isVideoAssetPortrait_)
    {
        FirstAssetScaleToFitRatio = 320.0/videoAssetTrack.naturalSize.height;
        CGAffineTransform FirstAssetScaleFactor = CGAffineTransformMakeScale(FirstAssetScaleToFitRatio,FirstAssetScaleToFitRatio);
        [videolayerInstruction setTransform:CGAffineTransformConcat(videoAssetTrack.preferredTransform, FirstAssetScaleFactor) atTime:kCMTimeZero];
    }
    else
    {
        CGAffineTransform FirstAssetScaleFactor = CGAffineTransformMakeScale(FirstAssetScaleToFitRatio,FirstAssetScaleToFitRatio);
        [videolayerInstruction setTransform:CGAffineTransformConcat(CGAffineTransformConcat(videoAssetTrack.preferredTransform, FirstAssetScaleFactor),CGAffineTransformMakeTranslation(0, 160)) atTime:kCMTimeZero];
    }
    [videolayerInstruction setOpacity:0.0 atTime:inTime];
    
    return videolayerInstruction;
}

// Convert 'space' char
- (NSString *)returnFormatString:(NSString *)str
{
    return [str stringByReplacingOccurrencesOfString:@" " withString:@""];
}

#pragma mark - Export Progress Callback
- (void)retrievingExportProgress
{
    if (_exportSession && _exportProgressBlock)
    {
        self.exportProgressBlock([NSNumber numberWithFloat:_exportSession.progress]);
    }
}

#pragma mark - NSUserDefaults
#pragma mark - setShouldRightRotate90
- (void)setShouldRightRotate90:(BOOL)shouldRotate withTrackID:(NSInteger)trackID
{
    NSString *identifier = [NSString stringWithFormat:@"TrackID_%ld", (long)trackID];
    NSUserDefaults *userDefaultes = [NSUserDefaults standardUserDefaults];
    if (shouldRotate)
    {
        [userDefaultes setBool:YES forKey:identifier];
    }
    else
    {
        [userDefaultes setBool:NO forKey:identifier];
    }
    
    [userDefaultes synchronize];
}

- (BOOL)shouldRightRotate90ByTrackID:(NSInteger)trackID
{
    NSUserDefaults *userDefaultes = [NSUserDefaults standardUserDefaults];
    NSString *identifier = [NSString stringWithFormat:@"TrackID_%ld", (long)trackID];
    BOOL result = [[userDefaultes objectForKey:identifier] boolValue];
    NSLog(@"shouldRightRotate90ByTrackID %@ : %@", identifier, result?@"Yes":@"No");
    
    if (result)
    {
        return YES;
    }
    else
    {
        return NO;
    }
}

#pragma mark - shouldVideoCrop
- (BOOL)shouldVideoCrop
{
    NSUserDefaults *userDefaultes = [NSUserDefaults standardUserDefaults];
    NSString *identifier = @"ShouldVideoCrop";
    BOOL result = [[userDefaultes objectForKey:identifier] boolValue];
    NSLog(@"shouldVideoCrop: %@ ", result?@"Yes":@"No");
    
    if (result)
    {
        return YES;
    }
    else
    {
        return NO;
    }
}

#pragma mark - TranstionAnimationType
- (TransitionType)getTranstionAnimationType
{
    NSString *flag = @"TranstionAnimationType";
    NSUserDefaults *userDefaultes = [NSUserDefaults standardUserDefaults];
    if ([userDefaultes objectForKey:flag])
    {
        return [[userDefaultes objectForKey:flag] integerValue];
    }
    else
    {
        return kTransitionTypeNone;
    }
}

@end

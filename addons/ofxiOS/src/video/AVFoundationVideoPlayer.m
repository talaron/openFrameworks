//
//  AVFoundationVideoPlayer.m
//  iOS+OFLib
//
//  Created by lukasz karluk on 21/05/12.
//

#import "AVFoundationVideoPlayer.h"

/* Asset keys */
NSString * const kTracksKey         = @"tracks";
NSString * const kPlayableKey		= @"playable";

/* PlayerItem keys */
NSString * const kStatusKey         = @"status";

/* AVPlayer keys */
NSString * const kRateKey			= @"rate";
NSString * const kCurrentItemKey	= @"currentItem";

//---------------------------------------------------------- video player view.
@implementation AVFoundationVideoPlayerView

+ (Class)layerClass {
	return [AVPlayerLayer class];
}


- (AVPlayer*)player {
	return [(AVPlayerLayer*)[self layer] player];
}


- (void)setPlayer:(AVPlayer*)player {
	[(AVPlayerLayer*)[self layer] setPlayer:player];
}

- (void)dealloc {
    self.player = nil;
    [super dealloc];
}

@end

//---------------------------------------------------------- video player.
@implementation AVFoundationVideoPlayer {
    AVPlayer * _player;
    id timeObserver;
    int timeObserverFps;
    
	CMSampleBufferRef videoSampleBuffer;
    CMSampleBufferRef audioSampleBuffer;
	CMTime videoTimestamp;
	CMTime videoTimestampLast;
    CMTime videoTime;
    CMTime audioTimestamp;
	CMTime duration;
    CMTime currentTime;
    CMTime sampleTime;
    float volume;
    float speed;
    float frameRate;

    NSInteger videoWidth;
    NSInteger videoHeight;
    
    BOOL bWillBeUpdatedExternally;
    BOOL bReady;
    BOOL bPlayStateBeforeLoad;
    BOOL bUpdateFirstFrame;
    BOOL bNewFrame;
    BOOL bPlaying;
    BOOL bFinished;
    BOOL bAutoPlayOnLoad;
    BOOL bLoop;
    BOOL bSeeking;
}

@synthesize delegate;
@synthesize playerView;
@synthesize player = _player;
@synthesize playerItem;
@synthesize asset;
@synthesize assetReader;
@synthesize assetReaderVideoTrackOutput;
@synthesize assetReaderAudioTrackOutput;

static const NSString * ItemStatusContext;

- (id)init {
    self = [super init];
    if(self) {
        /**
         *  initialise video player view to full screen by default.
         *  later the view frame can be changed if need be.
         */
        self.playerView = [[[AVFoundationVideoPlayerView alloc] initWithFrame:[UIScreen mainScreen].bounds] autorelease];
        self.playerView.backgroundColor = [UIColor blackColor];
        
        self.player = [[[AVPlayer alloc] init] autorelease];
        [(AVFoundationVideoPlayerView *)self.playerView setPlayer:_player];
        
        [_player addObserver:self 
                  forKeyPath:kRateKey 
                     options:NSKeyValueObservingOptionNew 
                     context:nil];
        
        timeObserver = nil;
        timeObserverFps = 30;
        
        videoSampleBuffer = nil;
        audioSampleBuffer = nil;
        videoTimestamp = kCMTimeZero;
        videoTimestampLast = kCMTimeZero;
        videoTime = kCMTimeZero;
        audioTimestamp = kCMTimeZero;
        duration = kCMTimeZero;
        currentTime = kCMTimeZero;
        sampleTime = kCMTimeInvalid;
        volume = 1;
        speed = 1;
        frameRate = 0;
        
        videoWidth = 0;
        videoHeight = 0;

        bWillBeUpdatedExternally = NO;
        bReady = NO;
        bPlayStateBeforeLoad = NO;
        bUpdateFirstFrame = YES;
        bNewFrame = NO;
        bPlaying = NO;
        bFinished = NO;
        bAutoPlayOnLoad = NO;
        bLoop = NO;
        bSeeking = NO;
    }
    return self;
}

- (void)dealloc {
    
    [(AVFoundationVideoPlayerView *)self.playerView setPlayer:nil];
    [self.playerView removeFromSuperview];
    self.playerView = nil;
    
    if(self.playerItem != nil) {
        NSNotificationCenter * notificationCenter = [NSNotificationCenter defaultCenter];
        [notificationCenter removeObserver:self 
                                      name:AVPlayerItemDidPlayToEndTimeNotification 
                                    object:self.playerItem];
        [self.playerItem removeObserver:self forKeyPath:kStatusKey];
        
        self.playerItem = nil;
    }
    
    [self removeTimeObserverFromPlayer];
    [_player removeObserver:self forKeyPath:kRateKey];
    
    self.player = nil;
    [_player release];
    
    [self.assetReader cancelReading];
	self.assetReader = nil;
    self.assetReaderVideoTrackOutput = nil;
    self.assetReaderAudioTrackOutput = nil;
    self.asset = nil;
    
    if(videoSampleBuffer) {
        CFRelease(videoSampleBuffer);
        videoSampleBuffer = nil;
    }
    
    if(audioSampleBuffer) {
        CFRelease(audioSampleBuffer);
        audioSampleBuffer = nil;
    }
    
    [super dealloc];
}

//---------------------------------------------------------- position / size.
- (void)setVideoPosition:(CGPoint)position {
    CGRect playerViewFrame = self.playerView.frame;
    playerViewFrame.origin = position;
    self.playerView.frame = playerViewFrame;
}

- (void)setVideoSize:(CGSize)size {
    CGRect playerViewFrame = self.playerView.frame;
    playerViewFrame.size = size;
    self.playerView.frame = playerViewFrame;
}

//---------------------------------------------------------- load / unload.
- (BOOL)loadWithFile:(NSString*)file {
    NSArray * fileSplit = [file componentsSeparatedByString:@"."];
    NSURL * fileURL = [[NSBundle mainBundle] URLForResource:[fileSplit objectAtIndex:0] 
                                              withExtension:[fileSplit objectAtIndex:1]];
    
	return [self loadWithURL:fileURL];
}

- (BOOL)loadWithPath:(NSString*)path {
    NSURL * fileURL = [NSURL fileURLWithPath:path];
	return [self loadWithURL:fileURL];
}

- (BOOL)loadWithURL:(NSURL*)url {

    [self unloadVideo];     // unload video if one is already loaded.
    
    self.asset = [AVURLAsset URLAssetWithURL:url options:nil];
    if(!self.asset) {
        return NO;
    }
    
    [self.asset loadValuesAsynchronouslyForKeys:[NSArray arrayWithObject:kTracksKey] completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            
            NSError * error = nil;
            AVKeyValueStatus status = [self.asset statusOfValueForKey:kTracksKey error:&error];
            
            if(status == AVKeyValueStatusLoaded) {
                
                duration = [self.asset duration];
                if(CMTimeCompare(duration, kCMTimeZero) == 0) {
                    return; // duration is zero.
                }
                
                if(!isfinite([self getDurationInSec])) {
                    return; // duration is infinite.
                }
                
                BOOL bOk = [self createAssetReaderWithTimeRange:CMTimeRangeMake(kCMTimeZero, duration)];
                if(!bOk) {
                    return; // asset reader not created.
                }
                
                videoSampleBuffer = [self.assetReaderVideoTrackOutput copyNextSampleBuffer];
                CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(videoSampleBuffer);
                CVPixelBufferLockBaseAddress(imageBuffer,0);
                videoWidth = CVPixelBufferGetWidth(imageBuffer);
                videoHeight = CVPixelBufferGetHeight(imageBuffer);
                CVPixelBufferUnlockBaseAddress(imageBuffer,0);
                
                NSLog(@"video loaded at %i x %i", videoWidth, videoHeight);
                
                CGRect playerViewFrame = self.playerView.frame;
                playerViewFrame.size.width = videoWidth;
                playerViewFrame.size.height = videoHeight;
                self.playerView.frame = playerViewFrame;
                
                NSArray * videoTracks = [self.asset tracksWithMediaType:AVMediaTypeVideo];
                if([videoTracks count] > 0) {
                    AVAssetTrack * track = [videoTracks objectAtIndex:0];
                    frameRate = track.nominalFrameRate;
                }
                
                //------------------------------------------------------------ create player item.
                self.playerItem = [AVPlayerItem playerItemWithAsset:self.asset];
                
                [self.playerItem addObserver:self 
                                  forKeyPath:kStatusKey
                                     options:0 
                                     context:&ItemStatusContext];
                
                NSNotificationCenter * notificationCenter = [NSNotificationCenter defaultCenter];
                [notificationCenter addObserver:self
                                       selector:@selector(playerItemDidReachEnd)
                                           name:AVPlayerItemDidPlayToEndTimeNotification
                                         object:self.playerItem];
                
                [_player replaceCurrentItemWithPlayerItem:self.playerItem];
                
                [self addTimeObserverToPlayer];
            }
            else {
                NSLog(@"The asset's tracks were not loaded:\n%@", [error localizedDescription]);
                return;
            }
        });
    }];
    
    return YES;
}

- (BOOL)createAssetReaderWithTimeRange:(CMTimeRange)timeRange {
    
    videoTimestamp = videoTimestampLast = timeRange.start;
    audioTimestamp = timeRange.start;
    
    NSError *error = nil;
    self.assetReader = [AVAssetReader assetReaderWithAsset:self.asset error:&error];
    
    if(error) {
        NSLog(@"assetReader: error during initialisation: %@", [error localizedDescription]);
        return NO;
    }
    self.assetReader.timeRange = timeRange;
    
    //------------------------------------------------------------ add video output.
    NSMutableDictionary * videoOutputSettings = [[[NSMutableDictionary alloc] init] autorelease];
    [videoOutputSettings setObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA]
                            forKey:(NSString*)kCVPixelBufferPixelFormatTypeKey];
    
    NSArray * videoTracks = [self.asset tracksWithMediaType:AVMediaTypeVideo];
    if([videoTracks count] > 0) {
        AVAssetTrack * videoTrack = [videoTracks objectAtIndex:0];
        self.assetReaderVideoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack
                                                                                      outputSettings:videoOutputSettings];
        
        if(self.assetReaderVideoTrackOutput == nil) {
            NSLog(@"assetReaderVideoTrackOutput failed to load.");
        }
        
        if([self.assetReader canAddOutput:self.assetReaderVideoTrackOutput]) {
            [self.assetReader addOutput:self.assetReaderVideoTrackOutput];
        } else {
            NSLog(@"assetReaderVideoTrackOutput cannot be add to assetReader");
        }
    }
    
    //------------------------------------------------------------ add audio output.
    double preferredHardwareSampleRate = [[AVAudioSession sharedInstance] currentHardwareSampleRate];
    
    AudioChannelLayout channelLayout;
    bzero(&channelLayout, sizeof(channelLayout));
    channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
    
    int numOfChannels = 1;
    if(channelLayout.mChannelLayoutTag == kAudioChannelLayoutTag_Stereo) {
        numOfChannels = 2;
    }
    
    NSDictionary * audioOutputSettings = nil;
    audioOutputSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                           [NSNumber numberWithInt:kAudioFormatLinearPCM], AVFormatIDKey,
                           [NSNumber numberWithFloat:preferredHardwareSampleRate], AVSampleRateKey,
                           [NSNumber numberWithInt:numOfChannels], AVNumberOfChannelsKey,
                           [NSData dataWithBytes:&channelLayout length:sizeof(AudioChannelLayout)], AVChannelLayoutKey,
                           [NSNumber numberWithInt:16], AVLinearPCMBitDepthKey,
                           [NSNumber numberWithBool:NO], AVLinearPCMIsNonInterleaved,
                           [NSNumber numberWithBool:NO], AVLinearPCMIsFloatKey,
                           [NSNumber numberWithBool:NO], AVLinearPCMIsBigEndianKey,
                           nil];
    
    NSArray * audioTracks = [self.asset tracksWithMediaType:AVMediaTypeAudio];
    if([audioTracks count] > 0) {
        AVAssetTrack * audioTrack = [audioTracks objectAtIndex:0];
        self.assetReaderAudioTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack
                                                                                      outputSettings:audioOutputSettings];
        
        if(self.assetReaderAudioTrackOutput == nil) {
            NSLog(@"assetReaderAudioTrackOutput failed to load.");
        }
        
        if([self.assetReader canAddOutput:self.assetReaderAudioTrackOutput]) {
            [self.assetReader addOutput:self.assetReaderAudioTrackOutput];
        } else {
            NSLog(@"assetReaderAudioTrackOutput cannot be add to assetReader");
        }
    }
    
    //------------------------------------------------------------ start reading.
    BOOL bOk = [self.assetReader startReading];
    if(!bOk ) {
        NSLog(@"assetReader couldn't startReading: %@", [self.assetReader error]);
    }
    
    return YES;
}

- (void)unloadVideo {
    
    bReady = NO;
    bPlayStateBeforeLoad = NO;
    bUpdateFirstFrame = YES;
    bNewFrame = NO;
    bPlaying = NO;
    bFinished = NO;
    
    videoTimestamp = kCMTimeZero;
    videoTimestampLast = kCMTimeZero;
    videoTime = kCMTimeZero;
    audioTimestamp = kCMTimeZero;
    duration = kCMTimeZero;
    currentTime = kCMTimeZero;
    sampleTime = kCMTimeInvalid;

    videoWidth = 0;
    videoHeight = 0;
    
    if(self.playerItem != nil) {
        [self.playerItem removeObserver:self forKeyPath:kStatusKey];
        
        NSNotificationCenter * notificationCenter = [NSNotificationCenter defaultCenter];
        [notificationCenter removeObserver:self 
                                      name:AVPlayerItemDidPlayToEndTimeNotification 
                                    object:self.playerItem];
        self.playerItem = nil;
    }
    
    [self.assetReader cancelReading];
	self.assetReader = nil;
    self.assetReaderVideoTrackOutput = nil;
    self.assetReaderAudioTrackOutput = nil;
    self.asset = nil;
    
    if(videoSampleBuffer) {
        CFRelease(videoSampleBuffer);
        videoSampleBuffer = nil;
    }
    
    if(audioSampleBuffer) {
        CFRelease(audioSampleBuffer);
        audioSampleBuffer = nil;
    }
    
	[self removeTimeObserverFromPlayer];
}

//---------------------------------------------------------- player callbacks.
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    
    if(context == &ItemStatusContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            bReady = true;
            [self update]; // update as soon is ready so pixels are loaded.
            [self setVolume:volume]; // set volume for current video.
            if([self.delegate respondsToSelector:@selector(playerReady)]) {
                [self.delegate playerReady];
            }
            if(bAutoPlayOnLoad || bPlayStateBeforeLoad) {
                [self play];
            }
        });
        return;
    }
    
    if(![self isReady]) {
        return;
    }
    
    BOOL b1 = _player != nil;
    BOOL b2 = object == _player;
    BOOL b3 = [keyPath isEqualToString:kRateKey];
    
    if(b1 && b2 && b3) {
		float rate = [[change objectForKey:@"new"] floatValue];
        bPlaying = rate != 0;
        return;
    }
    
    [super observeValueForKeyPath:keyPath 
                         ofObject:object
                           change:change 
                          context:context];
}

- (void)playerItemDidReachEnd {
    bFinished = YES;
    bPlaying = NO;
    if([self.delegate respondsToSelector:@selector(playerDidFinishPlayingVideo)]) {
        [self.delegate playerDidFinishPlayingVideo];
    }
    if(bLoop) {
        bFinished = NO;
        [self seekToStart];
        [self play];
    }
}

//---------------------------------------------------------- update.
- (void)update {
    /**
     *  return if,
     *  video is not yet loaded,
     *  video is finished playing.
     */
    if(![self isReady] || [self isFinished]) {
        bNewFrame = NO;
        return;
    }

    /**
     *  in most cases we check at what time the video player is up to,
     *  and use the time for sampling buffers in the code below.
     *  but if a sampleTime is provided then we use it instead of video player time.
     *  sampleTime is used when synchronous time is needed (video player plays asynchronously),
     *  such as when needing to access the video frames, frame by frame.
     *  sampleTime is cleared (invalidated) on every frame so it must be set before calling update.
     */
    CMTime time = kCMTimeZero;
    if(CMTIME_IS_VALID(sampleTime)) {
        time = sampleTime;
        sampleTime = kCMTimeInvalid;
        if(CMTIME_COMPARE_INLINE(time, <, kCMTimeZero)) {
            time = kCMTimeZero;
        } else if(CMTIME_COMPARE_INLINE(time, >, duration)) {
            time = duration;
        }
    } else {
        time = [_player currentTime];
    }
    
    if(bUpdateFirstFrame) {
        /**
         *  this forces the first frame to be updated.
         *  here the values for time and currentTime are both zero.
         *  so this is to get around the progress check below.
         */
        bUpdateFirstFrame = NO;
    } else if(CMTimeCompare(time, currentTime) == 0) {
        bNewFrame = NO;
        return; // no progress made.
    }
    currentTime = time;
    
    if(self.assetReader == nil) {
        if(bSeeking == true) {
            // video player is seeking to new position.
            // asset reader can only be created when seeking has finished.
            return;
        }
        
        [self createAssetReaderWithTimeRange:CMTimeRangeMake(currentTime, duration)];
    }
    
    if(self.assetReader.status != AVAssetReaderStatusReading) {
        bNewFrame = NO;
        return;
    }

    //---------------------------------------------------------- audio buffer.
    while(self.assetReaderAudioTrackOutput != nil &&                // asset has a audio track.
          self.assetReader.status == AVAssetReaderStatusReading &&  // asset read is in reading state.
          ((CMTimeCompare(audioTimestamp, currentTime) == -1) ||    // timestamp is less then currentTime.
           (CMTimeCompare(audioTimestamp, currentTime) == 0)))      // timestamp is equal currentTime.
    {
        CMSampleBufferRef audioBufferTemp;
        @try {
            audioBufferTemp = [self.assetReaderAudioTrackOutput copyNextSampleBuffer];
        } @catch (NSException * e) {
            break;
        }
        
        if(audioBufferTemp) {
            if(audioSampleBuffer) { // release old buffer.
                CFRelease(audioSampleBuffer);
                audioSampleBuffer = nil;
            }
            audioSampleBuffer = audioBufferTemp; // save reference to new buffer.
            
            audioTimestamp = CMSampleBufferGetPresentationTimeStamp(audioSampleBuffer);
        } else {
            break;
        }
    }
    
    //---------------------------------------------------------- video buffer.
    BOOL bCopiedNewSamples = NO;
    while(self.assetReaderVideoTrackOutput != nil &&                    // asset has a video track.
          self.assetReader.status == AVAssetReaderStatusReading &&      // asset read is in reading state.
          ((CMTimeCompare(videoTimestamp, currentTime) == -1) ||        // timestamp is less then currentTime.
          (CMTimeCompare(videoTimestamp, currentTime) == 0)))           // timestamp is equal currentTime.
    {
        CMSampleBufferRef videoBufferTemp;
        @try {
            videoBufferTemp = [self.assetReaderVideoTrackOutput copyNextSampleBuffer];
        } @catch (NSException * e) {
            break;
        }
        
        if(videoBufferTemp) {
            if(videoSampleBuffer) { // release old buffer.
                CFRelease(videoSampleBuffer);
                videoSampleBuffer = nil;
            }
            videoSampleBuffer = videoBufferTemp; // save reference to new buffer.
            
            videoTimestamp = CMSampleBufferGetPresentationTimeStamp(videoSampleBuffer);
            
            bCopiedNewSamples = YES;
        } else {
            break;
        }
    }
    
    if(bCopiedNewSamples == true) {
        bNewFrame = CMTimeCompare(videoTimestamp, videoTimestampLast) == 1;
        if(bNewFrame) {
            videoTimestampLast = videoTimestamp;
            videoTime = videoTimestamp;
        }
        
        if([self.delegate respondsToSelector:@selector(playerDidProgress)]) {
            [self.delegate playerDidProgress];
        }
    }
}

- (void)addTimeObserverToPlayer {
    if(bWillBeUpdatedExternally) {
        return;
    }
    
	if(timeObserver){
		return;
    }
    
	double interval = 1.0 / (double)timeObserverFps;
	
	timeObserver = [[_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(interval, NSEC_PER_SEC) 
                                                          queue:dispatch_get_main_queue() usingBlock:
                     ^(CMTime time) {
                         [self update];
                     }] retain];
}

- (void)removeTimeObserverFromPlayer {
	if(timeObserver) {
		[_player removeTimeObserver:timeObserver];
		[timeObserver release];
		timeObserver = nil;
	}
}

//---------------------------------------------------------- play / pause.
- (void)play {
    if([self isReady]) {
        if(![self isPlaying]) {
            [self togglePlayPause];
        }
    } else {
        bPlayStateBeforeLoad = YES;
    }
}

- (void)pause {
    if([self isReady]) {
        if([self isPlaying]) {
            [self togglePlayPause];
        }
    } else {
        bPlayStateBeforeLoad = NO;
    }
}

- (void)togglePlayPause {
	bPlaying = !bPlaying;
    if([self isPlaying]) {
        if([self isFinished]) {
            [self seekToStart];
            bFinished = NO;
        }
        [_player play];
    } else {
        [_player pause];
    }
}

//---------------------------------------------------------- seek.
- (void)seekToStart {
	[self seekToTime:kCMTimeZero withTolerance:kCMTimeZero];
}

- (void)seekToTime:(CMTime)time {
	[self seekToTime:time withTolerance:kCMTimeZero];
}

- (void)seekToTime:(CMTime)time 
     withTolerance:(CMTime)tolerance {
    
	if(![self isReady]) {
		return;
    }
    
    if([self isFinished]) {
        bFinished = NO;
    }
    
    [self.assetReader cancelReading];
	self.assetReader = nil;
    self.assetReaderVideoTrackOutput = nil;
    self.assetReaderAudioTrackOutput = nil;
    
    bSeeking = YES;
    
    [_player seekToTime:time
        toleranceBefore:tolerance
         toleranceAfter:tolerance
      completionHandler:^(BOOL finished) {
          
          bSeeking = NO;
          
          if([self.delegate respondsToSelector:@selector(playerDidFinishSeeking)]) {
              [self.delegate playerDidFinishSeeking];
          }
          
      }];
}

//---------------------------------------------------------- states.
- (BOOL)isReady {
    return bReady;
}

- (BOOL)isPlaying {
    return bPlaying;
}

- (BOOL)isNewFrame {
    return bNewFrame;
}

- (BOOL)isFinished {
    return bFinished;
}

//---------------------------------------------------------- getters / setters.
- (CVImageBufferRef)getCurrentFrame {
	return CMSampleBufferGetImageBuffer(videoSampleBuffer);
}

- (CMSampleBufferRef)getVideoSampleBuffer {
    return videoSampleBuffer;
}

- (CMSampleBufferRef)getAudioSampleBuffer {
    return audioSampleBuffer;
}

- (NSInteger)getWidth {
    return videoWidth;
}

- (NSInteger)getHeight {
    return videoHeight;
}

- (void)setSampleTimeInSec:(double)time {
    [self setSampleTime:CMTimeMakeWithSeconds(time, NSEC_PER_SEC)];
}

- (void)setSampleTime:(CMTime)time {
    sampleTime = time;
}

- (CMTime)getVideoTime {
    return videoTime;
}

- (double)getVideoTimeInSec {
    return CMTimeGetSeconds(videoTime);
}

- (CMTime)getCurrentTime {
    return currentTime;
}

- (double)getCurrentTimeInSec {
    return CMTimeGetSeconds(currentTime);
}

- (CMTime)getDuration {
    return duration;
}

- (double)getDurationInSec {
    return CMTimeGetSeconds(duration);
}

- (float)getFrameRate{
    return frameRate;
}

- (int)getDurationInFrames{
    return [self getDurationInSec] * [self getFrameRate];
}

- (int)getCurrentFrameNum{
    return [self getCurrentTimeInSec] * [self getFrameRate];
}

- (void)setPosition:(float)position {
    double time = [self getDurationInSec] * position;
    [self seekToTime:CMTimeMakeWithSeconds(time, NSEC_PER_SEC)];
}

- (void)setFrame:(int)frame{
    float position = frame / (float)[self getDurationInFrames];
    [self setPosition:position];
}

- (float)getPosition {
    return ([self getCurrentTimeInSec] / [self getDurationInSec]);
}

- (void)setVolume:(float)value {
    volume = value;
    
    if(![self isReady]) {
        return;
    }
    
    NSArray * audioTracks = [self.asset tracksWithMediaType:AVMediaTypeAudio];
    NSMutableArray * allAudioParams = [NSMutableArray array];
    for(AVAssetTrack * track in audioTracks) {
        AVMutableAudioMixInputParameters * audioInputParams = [AVMutableAudioMixInputParameters audioMixInputParameters];
        [audioInputParams setVolume:volume atTime:kCMTimeZero];
        [audioInputParams setTrackID:[track trackID]];
        [allAudioParams addObject:audioInputParams];
    }
    
    AVMutableAudioMix * audioMix = [AVMutableAudioMix audioMix];
    [audioMix setInputParameters:allAudioParams];
        
    [self.playerItem setAudioMix:audioMix];
}

- (float)getVolume {
    return volume;
}

- (void)setLoop:(BOOL)value {
    bLoop = value;
}

- (BOOL)getLoop {
    return bLoop;
}

- (void)setSpeed:(float)value {
    speed = value;
}

- (float)getSpeed {
    return speed;
}

- (void)setAutoplay:(BOOL)value {
    bAutoPlayOnLoad = value;
}

- (BOOL)getAutoplay {
    return bAutoPlayOnLoad;
}

- (void)setWillBeUpdatedExternally:(BOOL)value {
    bWillBeUpdatedExternally = value;
}

//---------------------------------------------------------- uiimage.
UIImage * imageFromSampleBuffer(CMSampleBufferRef sampleBuffer) {
    
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    // Lock the base address of the pixel buffer.
    CVPixelBufferLockBaseAddress(imageBuffer,0);
    
    // Get the number of bytes per row for the pixel buffer.
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    // Get the pixel buffer width and height.
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    
    // Create a device-dependent RGB color space.
    static CGColorSpaceRef colorSpace = NULL;
    if (colorSpace == NULL) {
        colorSpace = CGColorSpaceCreateDeviceRGB();
        if (colorSpace == NULL) {
            // Handle the error appropriately.
            return nil;
        }
    }
    
    // Get the base address of the pixel buffer.
    void *baseAddress = CVPixelBufferGetBaseAddress(imageBuffer);
    // Get the data size for contiguous planes of the pixel buffer.
    size_t bufferSize = CVPixelBufferGetDataSize(imageBuffer);
    
    // Create a Quartz direct-access data provider that uses data we supply.
    CGDataProviderRef dataProvider =
    CGDataProviderCreateWithData(NULL, baseAddress, bufferSize, NULL);
    // Create a bitmap image from data supplied by the data provider.
    CGImageRef cgImage =
    CGImageCreate(width, height, 8, 32, bytesPerRow,
                  colorSpace, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
                  dataProvider, NULL, true, kCGRenderingIntentDefault);
    CGDataProviderRelease(dataProvider);
    
    // Create and return an image object to represent the Quartz image.
    UIImage *image = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    
    CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
    
    return image;
}

@end

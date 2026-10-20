// Tatakan media adapter.
// macOS 15.4+ blocks MediaRemote for normal apps; Apple's own /usr/bin/perl is still allowed.
// Tatakan runs: /usr/bin/perl -e '<loader>' libTatakanMedia.dylib
// → this library streams now-playing state as JSON lines on stdout,
//   and reads commands on stdin: toggle | next | prev | seek <seconds>
#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*IsPlayingFn)(dispatch_queue_t, void (^)(BOOL));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef NSString *(*ClientBundleFn)(id);
typedef Boolean (*SendCommandFn)(int, NSDictionary *);
typedef void (*SetElapsedFn)(double);
typedef void (*RegisterFn)(dispatch_queue_t);

static GetInfoFn getInfo;
static IsPlayingFn isPlaying;
static GetClientFn getClient;
static ClientBundleFn clientBundle;
static SendCommandFn sendCommand;
static SetElapsedFn setElapsed;
static NSString *lastLine;
static NSUInteger lastArtHash;
static NSString *artPath;
static NSString *artDir;

static void emit(NSDictionary *info, BOOL playing, NSString *bundle) {
    NSMutableDictionary *o = [NSMutableDictionary dictionary];
    o[@"title"] = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"";
    o[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
    o[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
    o[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
    o[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0;
    NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    o[@"timestamp"] = @(ts ? ts.timeIntervalSince1970 : NSDate.date.timeIntervalSince1970);
    o[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @0;
    o[@"playing"] = @(playing);
    o[@"bundle"] = bundle ?: @"";

    NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if ([art isKindOfClass:NSData.class] && art.length > 0) {
        NSUInteger h = art.length ^ (NSUInteger)[o[@"title"] hash];
        if (h != lastArtHash) {
            lastArtHash = h;
            artPath = [artDir stringByAppendingPathComponent:[NSString stringWithFormat:@"art-%lu.img", (unsigned long)h]];
            [art writeToFile:artPath atomically:YES];
        }
        o[@"art"] = artPath ?: @"";
    } else {
        o[@"art"] = @"";
    }

    NSData *json = [NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingSortedKeys error:nil];
    NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    if (line && ![line isEqualToString:lastLine]) {
        lastLine = line;
        printf("%s\n", line.UTF8String);
        fflush(stdout);
    }
}

static void poll(void) {
    dispatch_queue_t q = dispatch_get_main_queue();
    getInfo(q, ^(NSDictionary *info) {
        isPlaying(q, ^(BOOL playing) {
            if (getClient && clientBundle) {
                getClient(q, ^(id client) {
                    NSString *b = client ? clientBundle(client) : nil;
                    emit(info ?: @{}, playing, b);
                });
            } else {
                emit(info ?: @{}, playing, nil);
            }
        });
    });
}

static void readCommands(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char buf[256];
        while (fgets(buf, sizeof buf, stdin)) {
            NSString *cmd = [[NSString stringWithUTF8String:buf]
                             stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([cmd isEqualToString:@"toggle"]) sendCommand(2, nil);
                else if ([cmd isEqualToString:@"next"]) sendCommand(4, nil);
                else if ([cmd isEqualToString:@"prev"]) sendCommand(5, nil);
                else if ([cmd hasPrefix:@"seek "] && setElapsed) setElapsed([[cmd substringFromIndex:5] doubleValue]);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ poll(); });
            });
        }
        exit(0); // Tatakan quit → stdin closed
    });
}

void tatakan_stream(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) { printf("{\"error\":\"no MediaRemote\"}\n"); fflush(stdout); return; }
    getInfo = (GetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    isPlaying = (IsPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getClient = (GetClientFn)dlsym(h, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = (ClientBundleFn)dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
    sendCommand = (SendCommandFn)dlsym(h, "MRMediaRemoteSendCommand");
    setElapsed = (SetElapsedFn)dlsym(h, "MRMediaRemoteSetElapsedTime");
    if (!getInfo || !isPlaying || !sendCommand) { printf("{\"error\":\"missing symbols\"}\n"); fflush(stdout); return; }

    const char *dir = getenv("TATAKAN_ART_DIR");
    artDir = dir ? [NSString stringWithUTF8String:dir] : NSTemporaryDirectory();
    [NSFileManager.defaultManager createDirectoryAtPath:artDir withIntermediateDirectories:YES attributes:nil error:nil];

    readCommands();

    // Event-driven: MediaRemote posts notifications when the track, play state or app changes.
    // We only re-read on those (coalesced), plus a slow 15 s safety poll — no tight loop.
    RegisterFn reg = (RegisterFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (reg) reg(dispatch_get_main_queue());
    __block BOOL pending = NO;
    void (^schedule)(NSNotification *) = ^(NSNotification *n) {
        if (pending) return;
        pending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            pending = NO; poll();
        });
    };
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:schedule];
    }
    poll();
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), 15 * NSEC_PER_SEC, 2 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(t, ^{ poll(); });
    dispatch_resume(t);
    CFRunLoopRun();
}

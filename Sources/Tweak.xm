#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <jsi/jsi.h>
#import <functional>
#import <unistd.h>

#import "LoaderConfig.h"
#import "Logger.h"
#import "Utils.h"
#import "JSI.h"
#import "RCTHost.h"
#import "RCTInstance.h"
#import "Fonts.h"
#import "Settings.h"

using namespace facebook;

static jsi::Runtime *gRuntime = NULL;
NSString *bunnyPatchesBundlePath;
static LoaderConfig  *loaderConfig;
static NSTimeInterval shakeStartTime = 0;
static BOOL           isShaking      = NO;

#define RAIN_RELEASE_BASE @"https://codeberg.org/raincord/rain/releases/download/latest/"

// Hermes bytecode version of the running Discord build (0 = unknown). Rain's
// precompiled bundle only runs on a matching version, so newer Discord builds
// need a different .hbc or the plain JS bundle.
static int  gHermesBytecodeVersion = 0;
static BOOL gPromptRestartOnDownload = NO;

static int readHermesBytecodeVersion(jsi::Runtime &runtime)
{
    try
    {
        jsi::Value internal = runtime.global().getProperty(runtime, "HermesInternal");
        if (!internal.isObject()) return 0;
        jsi::Object internalObj = internal.asObject(runtime);

        jsi::Value getProps = internalObj.getProperty(runtime, "getRuntimeProperties");
        if (!getProps.isObject() || !getProps.asObject(runtime).isFunction(runtime)) return 0;

        jsi::Value props =
            getProps.asObject(runtime).asFunction(runtime).callWithThis(runtime, internalObj);
        if (!props.isObject()) return 0;

        jsi::Value version = props.asObject(runtime).getProperty(runtime, "Bytecode Version");
        return version.isNumber() ? (int)version.getNumber() : 0;
    }
    catch (const std::exception &e)
    {
        BunnyLog(@"readHermesBytecodeVersion: %s", e.what());
        return 0;
    }
}

// Returns the bytecode version stored in a Hermes bundle header, or 0 for plain JS.
static int bundleBytecodeVersion(NSData *data)
{
    if (data.length < 12) return 0;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    if (!(bytes[0] == 0xC6 && bytes[1] == 0x1F && bytes[2] == 0xBC && bytes[3] == 0x03)) return 0;
    uint32_t version;
    memcpy(&version, bytes + 8, sizeof(version));
    return (int)version;
}

static NSArray<NSURL *> *resolveDownloadURLs(void)
{
    LoaderConfig *fresh = [LoaderConfig getLoaderConfig];
    if (fresh.customLoadUrlEnabled && fresh.customLoadUrl)
    {
        return @[ fresh.customLoadUrl ];
    }

    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    if (gHermesBytecodeVersion > 0)
    {
        NSString *hbc = [NSString stringWithFormat:@"rain.%d.hbc", gHermesBytecodeVersion];
        [urls addObject:[NSURL URLWithString:[RAIN_RELEASE_BASE stringByAppendingString:hbc]]];
    }
    [urls addObject:[NSURL URLWithString:[RAIN_RELEASE_BASE stringByAppendingString:@"rain.js"]]];
    return urls;
}

static dispatch_queue_t fsQueue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("app.rain.fsQueue", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void downloadBundleFromURLs(NSURL *rainDir, NSArray<NSURL *> *urls)
{
    if (urls.count == 0) return;

    NSURL *bundleFileURL = [rainDir URLByAppendingPathComponent:@"bundle.js"];
    NSURL *targetURL = urls.firstObject;
    NSArray<NSURL *> *remaining = [urls subarrayWithRange:NSMakeRange(1, urls.count - 1)];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:targetURL
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                                                   timeoutInterval:15.0];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *etagFileURL = [rainDir URLByAppendingPathComponent:@"etag.txt"];

    __block NSString *etag = nil;
    dispatch_sync(fsQueue(), ^{
        if ([fm fileExistsAtPath:bundleFileURL.path])
            etag = [NSString stringWithContentsOfURL:etagFileURL encoding:NSUTF8StringEncoding error:nil];
    });
    if (etag)
        [req setValue:etag forHTTPHeaderField:@"If-None-Match"];

    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    [[session dataTaskWithRequest:req
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if ([response isKindOfClass:[NSHTTPURLResponse class]])
        {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            if (http.statusCode == 200 && data.length > 0)
            {
                dispatch_sync(fsQueue(), ^{
                    [data writeToURL:bundleFileURL atomically:YES];
                    NSString *newEtag = [http valueForHTTPHeaderField:@"Etag"];
                    if (newEtag)
                        [newEtag writeToURL:etagFileURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    else
                        [fm removeItemAtURL:etagFileURL error:nil];
                });
                BunnyLog(@"downloadBundleForNextLaunch: saved %@", targetURL.lastPathComponent);

                // First install: Rain only runs from the cached bundle, so ask for a restart
                // instead of leaving Discord without Rain and no explanation.
                if (gPromptRestartOnDownload)
                {
                    gPromptRestartOnDownload = NO;
                    showErrorAlert(@"Rain Downloaded", @"Discord will restart to load Rain.", ^{
                        reloadApp(getKeyWindow().rootViewController);
                    });
                }
            }
            else if (http.statusCode != 304 && remaining.count > 0)
            {
                BunnyLog(@"downloadBundleForNextLaunch: %@ returned %ld, trying %@",
                         targetURL.lastPathComponent, (long)http.statusCode,
                         remaining.firstObject.lastPathComponent);
                downloadBundleFromURLs(rainDir, remaining);
            }
        }
        else if (error)
        {
            BunnyLog(@"downloadBundleForNextLaunch: Error: %@", error.localizedDescription);
        }
        [session finishTasksAndInvalidate];
    }] resume];
}

static void downloadBundleForNextLaunch(NSURL *rainDir)
{
    downloadBundleFromURLs(rainDir, resolveDownloadURLs());
}

typedef id (^BridgeHandler)(NSArray *args);

static NSDictionary<NSString *, BridgeHandler> *bridgeHandlers(void)
{
    static NSDictionary<NSString *, BridgeHandler> *handlers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handlers = @{
            @"applemusic.get": ^id(NSArray *args) {
                MPMediaLibraryAuthorizationStatus authorization = [MPMediaLibrary authorizationStatus];

                switch (authorization) {
                    case MPMediaLibraryAuthorizationStatusNotDetermined:
                        return @{
                            @"authorization": @"notDetermined"
                        };
                    case MPMediaLibraryAuthorizationStatusDenied:
                        return @{
                            @"authorization": @"denied"
                        };
                    case MPMediaLibraryAuthorizationStatusRestricted:
                        return @{
                            @"authorization": @"restricted"
                        };
                    case MPMediaLibraryAuthorizationStatusAuthorized: {
                        MPMusicPlayerController *player = [MPMusicPlayerController systemMusicPlayer];
                        MPMediaItem *song = player.nowPlayingItem;

                        if (player.playbackState == MPMusicPlaybackStatePlaying && song) {
                            return @{
                                @"authorization": @"authorized",
                                @"playing": @YES,
                                @"song": @{
                                    @"title": song.title,
                                    @"artist": song.artist,
                                    @"album": song.albumTitle,
                                    @"duration": @{
                                        @"elapsed": @(player.currentPlaybackTime),
                                        @"total": @(song.playbackDuration)
                                    }
                                }
                            };
                        } else {
                            return @{
                                @"authorization": @"authorized",
                                @"playing": @NO
                            };
                        }
                    }
                }
            },

            @"applemusic.request": ^id(NSArray *args) {
                [MPMediaLibrary requestAuthorization:^(MPMediaLibraryAuthorizationStatus status) {}];
                return [NSNull null];
            },

            @"updater.clear": ^id(NSArray *args) {
                NSURL *rainDirectory = getRainDirectory();
                NSFileManager *fm = [NSFileManager defaultManager];
                [fm removeItemAtURL:[rainDirectory URLByAppendingPathComponent:@"bundle.js"] error:nil];
                [fm removeItemAtURL:[rainDirectory URLByAppendingPathComponent:@"etag.txt"] error:nil];
                BunnyLog(@"[Updater] Cache cleared via JSI bridge");
                return [NSNull null];
            },

            @"updater.download": ^id(NSArray *args) {
                BunnyLog(@"[Updater] updater.download JSI bridge method called");
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSURL *rainDirectory = getRainDirectory();
                    downloadBundleForNextLaunch(rainDirectory);
                });
                return [NSNull null];
            },

            @"updater.reload": ^id(NSArray *args) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    BunnyLog(@"[Updater] Explicit JSI download + reload started");
                    NSURL *rainDirectory = getRainDirectory();
                    downloadBundleForNextLaunch(rainDirectory);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        reloadApp(getKeyWindow().rootViewController);
                    });
                });
                return [NSNull null];
            }
        };
    });
    return handlers;
}

static NSDictionary *callBridgeMethodHelper(NSString *methodName, NSArray *args)
{
    @try {
        BridgeHandler handler = bridgeHandlers()[methodName];
        if (!handler)
        {
            return @{@"error": [NSString stringWithFormat:@"Method not implemented: %@", methodName]};
        }

        __block id handlerResult;
        dispatch_sync(fsQueue(), ^{
            handlerResult = handler(args);
        });

        id responseVal = (handlerResult == nil) ? [NSNull null] : handlerResult;
        return @{@"result": responseVal};
    }
    @catch (NSException *exception) {
        return @{@"error": exception.reason ?: @"Unknown Objective-C exception"};
    }
}

static void injectPreBundle(jsi::Runtime &runtime)
{
    try
    {
        jsi::Object loaderObj(runtime);
        loaderObj.setProperty(runtime, "loaderName", jsi::String::createFromUtf8(runtime, "RainTweak"));
        loaderObj.setProperty(runtime, "loaderVersion", jsi::String::createFromUtf8(runtime, [PACKAGE_VERSION UTF8String]));
        loaderObj.setProperty(runtime, "hasThemeSupport", true);
        loaderObj.setProperty(runtime, "storedTheme", jsi::Value::null());
        loaderObj.setProperty(runtime, "fontPatch", 2);
        runtime.global().setProperty(runtime, "__RAIN_LOADER__", loaderObj);

        auto parsePayload = [](jsi::Runtime &rt, const jsi::Value *args, size_t count, NSString **methodOut, NSArray **argsOut) {
            if (count < 1 || !args[0].isObject()) {
                throw jsi::JSError(rt, "Expected a single payload object as argument.");
            }
            jsi::Object payload = args[0].asObject(rt);

            jsi::Value rainVal = payload.getProperty(rt, "rain");
            if (!rainVal.isObject()) throw jsi::JSError(rt, "Payload missing 'rain' object.");
            jsi::Object rain = rainVal.asObject(rt);

            jsi::Value methodVal = rain.getProperty(rt, "method");
            if (!methodVal.isString()) throw jsi::JSError(rt, "'method' property must be a string.");
            *methodOut = [JSI toNSString:methodVal runtime:rt];

            *argsOut = @[];
            jsi::Value argsVal = rain.getProperty(rt, "args");
            if (argsVal.isObject() && argsVal.asObject(rt).isArray(rt)) {
                *argsOut = [JSI toObjC:argsVal runtime:rt];
            }
        };

        auto syncCall = jsi::Function::createFromHostFunction(
            runtime,
            jsi::PropNameID::forUtf8(runtime, "__RAIN_BRIDGE_CALL_SYNC__"),
            1,
            [parsePayload](jsi::Runtime &rt, const jsi::Value &thisVal, const jsi::Value *args, size_t count) -> jsi::Value {
                NSString *methodName;
                NSArray *objcArgs;
                parsePayload(rt, args, count, &methodName, &objcArgs);

                NSDictionary *res = callBridgeMethodHelper(methodName, objcArgs);
                return [JSI fromObjC:res runtime:rt];
            }
        );
        runtime.global().setProperty(runtime, "__RAIN_BRIDGE_CALL_SYNC__", syncCall);

        auto asyncCall = jsi::Function::createFromHostFunction(
            runtime,
            jsi::PropNameID::forUtf8(runtime, "__RAIN_BRIDGE_CALL_ASYNC__"),
            1,
            [parsePayload](jsi::Runtime &rt, const jsi::Value &thisVal, const jsi::Value *args, size_t count) -> jsi::Value {
                NSString *methodName;
                NSArray *objcArgs;
                parsePayload(rt, args, count, &methodName, &objcArgs);

                jsi::Function promiseCtor = rt.global().getPropertyAsFunction(rt, "Promise");
                jsi::Function executor = jsi::Function::createFromHostFunction(rt, jsi::PropNameID::forUtf8(rt, "executor"), 2,
                    [methodName, objcArgs](jsi::Runtime &innerRt, const jsi::Value &thisVal, const jsi::Value *innerArgs, size_t innerCount) -> jsi::Value {
                        jsi::Function resolve = innerArgs[0].asObject(innerRt).asFunction(innerRt);
                        NSDictionary *res = callBridgeMethodHelper(methodName, objcArgs);
                        resolve.call(innerRt, [JSI fromObjC:res runtime:innerRt]);
                        return jsi::Value::undefined();
                    });
                return promiseCtor.callAsConstructor(rt, executor);
            }
        );
        runtime.global().setProperty(runtime, "__RAIN_BRIDGE_CALL_ASYNC__", asyncCall);

    }
    catch (const jsi::JSError &e) { BunnyLog(@"injectPreBundle: JSError: %s", e.what()); }
    catch (const std::exception &e) { BunnyLog(@"injectPreBundle: exception: %s", e.what()); }
}

static void executePreloads(jsi::Runtime &runtime, NSURL *rainDir)
{
    NSURL *preloadsDirectory = [rainDir URLByAppendingPathComponent:@"preloads"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:preloadsDirectory.path])
    {
        NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:preloadsDirectory
                                                           includingPropertiesForKeys:nil options:0 error:nil];
        for (NSURL *fileURL in contents)
        {
            if ([[fileURL pathExtension] isEqualToString:@"js"])
            {
                NSData *data = [NSData dataWithContentsOfURL:fileURL];
                if (data) [JSI evaluate:data tag:@"rain:preload" runtime:runtime];
            }
        }
    }
}

%hook RCTHost

- (void)instance:(id)instance didInitializeRuntime:(facebook::jsi::Runtime &)runtime
{
    gRuntime = &runtime;
    %orig;

    [loaderConfig loadConfig];
    NSURL *rainDir = getRainDirectory();
    injectPreBundle(runtime);

    gHermesBytecodeVersion = readHermesBytecodeVersion(runtime);
    BunnyLog(@"Discord Hermes bytecode version: %d", gHermesBytecodeVersion);

    // Prefer the Rain build shipped inside the tweak (Rain/rain.js, patched for the
    // Discord version we target) unless a custom bundle URL is configured. Never fall
    // through to the cached bundle after it ran: a half-initialised Rain plus a second
    // copy on top is worse than no Rain.
    LoaderConfig *config = [LoaderConfig getLoaderConfig];
    if (!(config.customLoadUrlEnabled && config.customLoadUrl))
    {
        NSString *embeddedPath = [bunnyPatchesBundlePath stringByAppendingPathComponent:@"rain.js"];
        NSData *embedded = [NSData dataWithContentsOfFile:embeddedPath];
        if (embedded.length > 0)
        {
            if ([JSI evaluate:embedded tag:@"rain:bundle" runtime:runtime])
                executePreloads(runtime, rainDir);
            else
                BunnyLog(@"Embedded Rain bundle failed to evaluate");
            return;
        }
        BunnyLog(@"No embedded Rain bundle at %@, using downloaded bundle", embeddedPath);
    }

    NSURL *bundleFileURL = [rainDir URLByAppendingPathComponent:@"bundle.js"];
    NSURL *etagFileURL   = [rainDir URLByAppendingPathComponent:@"etag.txt"];
    NSData *bundle = [NSData dataWithContentsOfURL:bundleFileURL];

    // A bundle compiled for another Hermes version (e.g. cached before a Discord
    // update) can never run; drop it so a compatible one is downloaded.
    int bundleVersion = bundleBytecodeVersion(bundle);
    if (bundleVersion > 0 && gHermesBytecodeVersion > 0 && bundleVersion != gHermesBytecodeVersion)
    {
        BunnyLog(@"Cached bundle is bytecode v%d, runtime is v%d; discarding", bundleVersion,
                 gHermesBytecodeVersion);
        [[NSFileManager defaultManager] removeItemAtURL:bundleFileURL error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:etagFileURL error:nil];
        bundle = nil;
    }

    if (bundle && bundle.length > 0)
    {
        if ([JSI evaluate:bundle tag:@"rain:bundle" runtime:runtime])
        {
            executePreloads(runtime, rainDir);
        }
        else
        {
            // Unusable bundle: remove it so the next launch fetches a fresh one. If the
            // precompiled bytecode failed, fall back to the plain JS bundle instead of
            // downloading the same .hbc again.
            [[NSFileManager defaultManager] removeItemAtURL:bundleFileURL error:nil];
            [[NSFileManager defaultManager] removeItemAtURL:etagFileURL error:nil];
            NSArray<NSURL *> *urls = resolveDownloadURLs();
            if (bundleVersion > 0 && urls.count > 1)
                urls = @[ urls.lastObject ];
            downloadBundleFromURLs(rainDir, urls);
        }
    }
    else
    {
        gPromptRestartOnDownload = YES;
        downloadBundleForNextLaunch(rainDir);
    }
}

%end

%hook UIWindow

- (void)motionBegan:(UIEventSubtype)motion withEvent:(UIEvent *)event
{
    if (motion == UIEventSubtypeMotionShake)
    {
        isShaking      = YES;
        shakeStartTime = [[NSDate date] timeIntervalSince1970];
    }
    %orig;
}

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event
{
    if (motion == UIEventSubtypeMotionShake && isShaking)
    {
        NSTimeInterval shakeDuration = [[NSDate date] timeIntervalSince1970] - shakeStartTime;
        if (shakeDuration >= 0.5 && shakeDuration <= 2.0)
            dispatch_async(dispatch_get_main_queue(), ^{ showSettingsSheet(); });
        isShaking = NO;
    }
    %orig;
}

%end

%ctor
{
    @autoreleasepool
    {
        BOOL newArchEnabled = YES;
        @try {
            id rawVal = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"RCTNewArchEnabled"];
            if (rawVal) newArchEnabled = [rawVal boolValue];
        }
        @catch (...) {
        }

        if (!newArchEnabled)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                showErrorAlert(@"Incompatible Discord Version",
                              @"This version of Discord is not using bridgeless "
                              @"Please update Discord to v332 or above",
                              nil);
            });
            return;
        }

        NSString *install_prefix = @"/var/jb";
        isJailbroken = [[NSFileManager defaultManager] fileExistsAtPath:install_prefix];
        BOOL jbPathExists = isJailbroken;

        NSString *bundlePath = [NSString stringWithFormat:@"%@/Library/Application Support/BunnyResources.bundle", install_prefix];
        NSString *jailedPath = [[NSBundle mainBundle].bundleURL.path stringByAppendingPathComponent:@"BunnyResources.bundle"];

        if (jbPathExists && [[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) {
            bunnyPatchesBundlePath = bundlePath;
        } else {
            bunnyPatchesBundlePath = jailedPath;
        }

        loaderConfig = [[LoaderConfig alloc] init];
        [loaderConfig loadConfig];

        %init;
    }
}

// Lettore di «In riproduzione» per Charland. Gira dentro /usr/bin/perl (un eseguibile di Apple, a cui MediaRemote
// risponde ancora da macOS 15.4): scrive una riga JSON a ogni cambiamento e legge i comandi da stdin.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <math.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*IsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);
typedef void (*SetElapsedFn)(double);
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*ClientBundleFn)(id);

static GetInfoFn getInfo;
static IsPlayingFn isPlaying;
static SendCommandFn sendCommand;
static SetElapsedFn setElapsed;
static GetClientFn getClient;
static ClientBundleFn clientBundle;
/// Per i siti nei browser il cliente è un processo di WebKit o di Chromium: l'app madre è il browser.
static ClientBundleFn clientParent;
static ClientBundleFn clientName;
static NSUInteger lastArtwork = 0;
static BOOL pending = NO;

/// Un testo, o niente se MediaRemote ha messo altro in quella voce.
static NSString *text(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

/// Un numero finito, o niente. Una diretta nel browser può dichiarare una durata infinita, e NSJSONSerialization con
/// un infinito o un NaN non restituisce nil: lancia un'eccezione, che chiudeva il lettore a ogni lettura.
static NSNumber *number(id value) {
    if (![value isKindOfClass:[NSNumber class]]) return nil;
    return isfinite([value doubleValue]) ? value : nil;
}

static void writeLine(NSDictionary *object) {
    if (![NSJSONSerialization isValidJSONObject:object]) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void emitNow(void) {
    getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef dict) {
        NSDictionary *info = (__bridge NSDictionary *)dict;
        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithObject:@"info" forKey:@"type"];
        if (info.count) {
            id v;
            if ((v = text(info[@"kMRMediaRemoteNowPlayingInfoTitle"]))) out[@"title"] = v;
            if ((v = text(info[@"kMRMediaRemoteNowPlayingInfoArtist"]))) out[@"artist"] = v;
            if ((v = text(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]))) out[@"album"] = v;
            if ((v = number(info[@"kMRMediaRemoteNowPlayingInfoDuration"]))) out[@"duration"] = v;
            if ((v = number(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]))) out[@"elapsed"] = v;
            if ((v = number(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]))) out[@"rate"] = v;
            NSDate *when = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if ([when isKindOfClass:[NSDate class]] && isfinite(when.timeIntervalSince1970)) out[@"timestamp"] = @(when.timeIntervalSince1970);
            NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            if ([art isKindOfClass:[NSData class]] && art.length > 0) {
                // la copertina viaggia solo quando cambia
                NSUInteger key = art.length ^ (NSUInteger)[[art subdataWithRange:NSMakeRange(0, MIN(art.length, 64))] hash];
                if (key != lastArtwork) { lastArtwork = key; out[@"artwork"] = [art base64EncodedStringWithOptions:0]; }
            } else if (lastArtwork != 0) { lastArtwork = 0; out[@"artwork"] = @""; }
        }
        isPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            out[@"playing"] = @(playing);
            if (getClient && clientBundle) {
                getClient(dispatch_get_main_queue(), ^(id client) {
                    if (client) {
                        CFStringRef bundle = clientBundle(client);
                        CFStringRef parent = clientParent ? clientParent(client) : NULL;
                        CFStringRef name = clientName ? clientName(client) : NULL;
                        if (bundle) out[@"client"] = (__bridge NSString *)bundle;
                        // l'app da aprire: il browser per i siti, l'app stessa per gli altri
                        if (parent && CFStringGetLength(parent) > 0) out[@"app"] = (__bridge NSString *)parent;
                        else if (bundle) out[@"app"] = (__bridge NSString *)bundle;
                        if (name && CFStringGetLength(name) > 0) out[@"appName"] = (__bridge NSString *)name;
                    }
                    writeLine(out);
                });
            } else {
                writeLine(out);
            }
        });
    });
}

/// Più avvisi di fila diventano una riga sola.
static void emit(void) {
    if (pending) return;
    pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        pending = NO;
        emitNow();
    });
}

static void handle(NSString *line) {
    NSArray *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject;
    if ([cmd isEqualToString:@"toggle"]) sendCommand(2, NULL);
    else if ([cmd isEqualToString:@"play"]) sendCommand(0, NULL);
    else if ([cmd isEqualToString:@"pause"]) sendCommand(1, NULL);
    else if ([cmd isEqualToString:@"next"]) sendCommand(4, NULL);
    else if ([cmd isEqualToString:@"previous"]) sendCommand(5, NULL);
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1 && setElapsed) setElapsed([parts[1] doubleValue]);
    else if ([cmd isEqualToString:@"refresh"]) emitNow();
}

void charland_nowplaying_run(void *perl, void *cv) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) { writeLine(@{@"type": @"error", @"message": @"MediaRemote"}); exit(2); }
    getInfo = (GetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    isPlaying = (IsPlayingFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    sendCommand = (SendCommandFn)dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = (SetElapsedFn)dlsym(mr, "MRMediaRemoteSetElapsedTime");
    getClient = (GetClientFn)dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = (ClientBundleFn)dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    clientParent = (ClientBundleFn)dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
    clientName = (ClientBundleFn)dlsym(mr, "MRNowPlayingClientGetDisplayName");
    RegisterFn reg = (RegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !isPlaying || !sendCommand || !reg) { writeLine(@{@"type": @"error", @"message": @"simboli"}); exit(2); }
    reg(dispatch_get_main_queue());
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *n) { emit(); }];
    }
    // i comandi, una riga per comando; stdin chiuso = Charland non c'è più, si esce
    dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    __block NSMutableString *buffer = [NSMutableString new];
    dispatch_source_set_event_handler(input, ^{
        char chunk[512];
        ssize_t n = read(STDIN_FILENO, chunk, sizeof chunk);
        if (n <= 0) exit(0);
        [buffer appendString:[[NSString alloc] initWithBytes:chunk length:n encoding:NSUTF8StringEncoding] ?: @""];
        NSRange r;
        while ((r = [buffer rangeOfString:@"\n"]).location != NSNotFound) {
            NSString *line = [buffer substringToIndex:r.location];
            [buffer deleteCharactersInRange:NSMakeRange(0, r.location + 1)];
            handle([line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]);
        }
    });
    dispatch_resume(input);
    writeLine(@{@"type": @"ready"});
    emitNow();
    CFRunLoopRun();
}

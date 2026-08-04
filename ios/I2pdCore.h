//  I2pdCore.h — ObjC facade between the i2pd C++ daemon core and the SwiftUI
//  app layer. All daemon control, config writing, keep-alive, backloop SSL and
//  the i2p browser scheme handler live in I2pdCore.mm; no UI code here.
//
//  This header is imported by the Swift bridging header, so it must stay pure
//  Objective-C (no C++).
//
//  NOTE: class properties are not auto-synthesized; every getter/setter is
//  implemented explicitly in I2pdCore.mm.

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

// WKURLSchemeHandler that fetches i2p-http / i2p-https requests through the
// local i2pd HTTP proxy at 127.0.0.1:<httpproxy port>.
@interface I2pdSchemeHandler : NSObject <WKURLSchemeHandler, NSURLSessionDelegate>
@end

@interface I2pdCore : NSObject

+ (void)prepare;  // OpenSSL init; call once at launch.

// ---- settings (persisted to NSUserDefaults) ----
@property (class, nonatomic) BOOL httpEnabled;
@property (class, nonatomic) NSInteger httpPort;
@property (class, nonatomic) BOOL socksEnabled;
@property (class, nonatomic) NSInteger socksPort;
@property (class, nonatomic) BOOL samEnabled;
@property (class, nonatomic) NSInteger samPort;
@property (class, nonatomic) NSString* logLevel;
@property (class, nonatomic) NSString* backloopHost;
@property (class, nonatomic) NSInteger backloopPort;
@property (class, nonatomic) BOOL keepAliveEnabled;
@property (class, nonatomic) NSString* ssid;
@property (class, nonatomic) NSInteger consolePort;

// ---- config files in <Documents>/i2pd ----
@property (class, nonatomic, readonly) NSString* configDir;
@property (class, nonatomic, readonly) NSString* configPath;
@property (class, nonatomic, readonly) NSString* customConfigPath;
@property (class, nonatomic, readonly) NSString* customConfigText;
+ (void)writeConfigFiles;
+ (void)writeCustomConfig:(NSString*)text;

// ---- router ----
@property (class, nonatomic, readonly) BOOL routerRunning;
@property (class, nonatomic, readonly) NSString* routerLog;
@property (class, nonatomic, readonly) NSString* vpnStatus;
+ (BOOL)startRouter;
+ (void)stopRouter;

// ---- tunnels ----
+ (NSArray<NSDictionary*>*)tunnels;
+ (void)saveTunnels:(NSArray<NSDictionary*>*)tunnels;

// ---- keep alive (silent audio) ----
+ (void)applyKeepAlive;

// ---- backloop SSL + local HTTPS server ----
@property (class, nonatomic, readonly) BOOL hasSslCert;
@property (class, nonatomic, readonly) NSString* sslExpiryString;
+ (BOOL)refreshSsl:(NSError**)error;
+ (void)startSslServer;
+ (void)stopSslServer;
+ (NSString* _Nullable)detectedSSID;

@end

NS_ASSUME_NONNULL_END

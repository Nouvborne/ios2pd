//
//  ios2pd — i2pd (I2P daemon) as an iOS app.
//
//  Links the i2pd C++ daemon core (DaemonUnix) into a small UIKit shell.
//  The router runs on a background thread; logs are captured through a
//  custom std::ostream and surfaced in the UI.
//
//  Tabs:
//   - Router   : start/stop the daemon, VPN status, live log.
//   - i2pd     : daemon settings (HTTP/SOCKS/SAM proxies, log level).
//   - Proxy    : backloop.dev integration - install a Wi-Fi proxy profile
//                (.mobileconfig), refresh the loopback SSL certificate, and
//                keep i2pd alive in the background.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>
#import <AVFoundation/AVFoundation.h>

#include <atomic>
#include <mutex>
#include <ostream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <unistd.h>
#include <cstring>

#include <openssl/ssl.h>
#include <openssl/err.h>

#include "Daemon.h"
#include "Log.h"
#include "Config.h"
#include "FS.h"

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------
static NSUserDefaults* UD() { return [NSUserDefaults standardUserDefaults]; }
static BOOL SettingBool(NSString* key, BOOL def) {
  id v = [UD() objectForKey:key];
  return v ? [v boolValue] : def;
}
static int SettingInt(NSString* key, int def) {
  id v = [UD() objectForKey:key];
  return v ? [v intValue] : def;
}
static NSString* SettingString(NSString* key, NSString* def) {
  NSString* v = [UD() stringForKey:key];
  return (v && v.length) ? v : def;
}

static NSString* const kHttpOn = @"i2pd_http_enabled";
static NSString* const kHttpPort = @"i2pd_http_port";
static NSString* const kSocksOn = @"i2pd_socks_enabled";
static NSString* const kSocksPort = @"i2pd_socks_port";
static NSString* const kSamOn = @"i2pd_sam_enabled";
static NSString* const kSamPort = @"i2pd_sam_port";
static NSString* const kLogLevel = @"i2pd_loglevel";
static NSString* const kBackloopHost = @"backloop_host";
static NSString* const kBackloopPort = @"backloop_https_port";
static NSString* const kKeepAlive = @"keepalive_audio";
static NSString* const kSslNotAfter = @"backloop_notafter";

// ---------------------------------------------------------------------------
// Daemon bridge
// ---------------------------------------------------------------------------
namespace {

std::mutex gLogMutex;
std::string gLog;
std::atomic<bool> gStarted{false};
std::thread gDaemonThread;

// A streambuf that appends every byte written by i2pd's logger into gLog.
struct IosLogBuf : std::streambuf {
  int overflow(int c) override {
    if (c != EOF) {
      std::lock_guard<std::mutex> lock(gLogMutex);
      gLog.push_back(static_cast<char>(c));
      if (gLog.size() > (256 * 1024)) {
        gLog.erase(0, gLog.size() - (256 * 1024));
      }
    }
    return c;
  }
};

bool StartDaemon() {
  if (gStarted.load()) return true;

  NSString* docs = [NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  std::string datadir =
      std::string(docs.UTF8String) + "/i2pd";

  std::vector<std::string> args = {
      "ios2pd",
      "--datadir=" + datadir,
      "--log=stdout",
      "--loglevel=" +
          std::string(SettingString(kLogLevel, @"info").UTF8String),
  };
  if (SettingBool(kHttpOn, YES)) {
    args.push_back("--httpproxy.enabled=true");
    args.push_back("--httpproxy.port=" + std::to_string(SettingInt(kHttpPort, 4444)));
  } else {
    args.push_back("--httpproxy.enabled=false");
  }
  if (SettingBool(kSocksOn, YES)) {
    args.push_back("--socksproxy.enabled=true");
    args.push_back("--socksproxy.port=" + std::to_string(SettingInt(kSocksPort, 4447)));
  } else {
    args.push_back("--socksproxy.enabled=false");
  }
  if (SettingBool(kSamOn, YES)) {
    args.push_back("--sam.enabled=true");
    args.push_back("--sam.port=" + std::to_string(SettingInt(kSamPort, 7656)));
  } else {
    args.push_back("--sam.enabled=false");
  }

  std::vector<char*> argv;
  argv.reserve(args.size());
  for (auto& a : args) argv.push_back(&a[0]);

  static IosLogBuf logBuf;
  static std::ostream logStream(&logBuf);
  std::shared_ptr<std::ostream> sink(&logStream, [](std::ostream*) {});

  if (!Daemon.init(static_cast<int>(argv.size()), argv.data(), sink)) {
    return false;
  }
  if (!Daemon.start()) {
    return false;
  }
  gStarted.store(true);
  gDaemonThread = std::thread([]() { Daemon.run(); });
  return true;
}

void StopDaemon() {
  if (!gStarted.load()) return;
  Daemon.running = false;
  if (gDaemonThread.joinable()) gDaemonThread.join();
  Daemon.stop();
  gStarted.store(false);
}

std::string TakeLog() {
  std::lock_guard<std::mutex> lock(gLogMutex);
  return gLog;
}

// Installs (or updates) the NEAppProxyProvider VPN profile that routes *.i2p
// traffic through the local i2pd SOCKS proxy. Requires the
// com.apple.developer.networking.networkextension entitlement at signing time.
void InstallVpnProfile() {
  NEAppProxyProviderManager* mgr =
      (NEAppProxyProviderManager*)[NEAppProxyProviderManager sharedManager];
  [mgr loadFromPreferencesWithCompletionHandler:^(NSError* _Nullable err) {
    NETunnelProviderProtocol* proto = [[NETunnelProviderProtocol alloc] init];
    proto.providerBundleIdentifier = @"org.nouvborne.ios2pd.appproxy";
    proto.serverAddress = @"i2pd";
    proto.providerConfiguration = @{
      @"proxyHost" : @"127.0.0.1",
      @"proxyPort" : @(SettingInt(kSocksPort, 4447)),
    };
    mgr.protocolConfiguration = proto;
    mgr.localizedDescription = @"ios2pd I2P VPN";
    mgr.enabled = YES;
    [mgr saveToPreferencesWithCompletionHandler:^(NSError* _Nullable saveErr) {
      if (saveErr) {
        NSLog(@"[ios2pd] VPN profile save failed: %@", saveErr);
      }
    }];
  }];
}

NSString* VpnStatusString() {
  NEVPNConnection* conn = [NEAppProxyProviderManager sharedManager].connection;
  switch (conn.status) {
    case NEVPNStatusInvalid:
      return @"not configured";
    case NEVPNStatusDisconnected:
      return @"Disconnected";
    case NEVPNStatusConnecting:
      return @"Connecting";
    case NEVPNStatusConnected:
      return @"Connected";
    case NEVPNStatusReasserting:
      return @"Reconnecting";
    case NEVPNStatusDisconnecting:
      return @"Disconnecting";
  }
  return @"?";
}

}  // namespace

// ---------------------------------------------------------------------------
// Background keep-alive (silent audio so the proxy stays up in Safari)
// ---------------------------------------------------------------------------
@interface KeepAlive : NSObject
+ (instancetype)shared;
- (void)apply;
@end

@implementation KeepAlive {
  AVAudioPlayer* _player;
}

+ (instancetype)shared {
  static KeepAlive* instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    instance = [[KeepAlive alloc] init];
  });
  return instance;
}

// 1 second of 8 kHz mono 16-bit PCM silence as a WAV.
+ (NSData*)silentWavData {
  const int sr = 8000, ch = 1, bits = 16;
  const int samples = sr * 1;
  const int dataSize = samples * (bits / 8);
  NSMutableData* d = [NSMutableData dataWithCapacity:44 + dataSize];
  uint8_t hdr[44] = {0};
  hdr[0] = 'R'; hdr[1] = 'I'; hdr[2] = 'F'; hdr[3] = 'F';
  uint32_t u = 36 + dataSize; memcpy(hdr + 4, &u, 4);
  hdr[8] = 'W'; hdr[9] = 'A'; hdr[10] = 'V'; hdr[11] = 'E';
  hdr[12] = 'f'; hdr[13] = 'm'; hdr[14] = 't'; hdr[15] = ' ';
  u = 16; memcpy(hdr + 16, &u, 4);
  uint16_t s = 1; memcpy(hdr + 20, &s, 2);
  s = ch; memcpy(hdr + 22, &s, 2);
  u = sr; memcpy(hdr + 24, &u, 4);
  u = sr * ch * (bits / 8); memcpy(hdr + 28, &u, 4);
  s = ch * (bits / 8); memcpy(hdr + 32, &s, 2);
  s = bits; memcpy(hdr + 34, &s, 2);
  hdr[36] = 'd'; hdr[37] = 'a'; hdr[38] = 't'; hdr[39] = 'a';
  u = dataSize; memcpy(hdr + 40, &u, 4);
  [d appendBytes:hdr length:44];
  [d increaseLengthBy:dataSize];
  return d;
}

- (void)apply {
  BOOL on = SettingBool(kKeepAlive, NO);
  AVAudioSession* session = [AVAudioSession sharedInstance];
  if (on) {
    [session setCategory:AVAudioSessionCategoryPlayback error:nil];
    [session setActive:YES error:nil];
    if (!_player) {
      NSData* wav = [[self class] silentWavData];
      NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ios2pd-silence.wav"];
      [wav writeToFile:path atomically:YES];
      _player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil];
      _player.numberOfLoops = -1;
      _player.volume = 0.0f;
      [_player prepareToPlay];
    }
    [_player play];
  } else {
    [_player stop];
    _player = nil;
    [session setActive:NO
           withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                 error:nil];
  }
}

@end

// ---------------------------------------------------------------------------
// backloop.dev SSL certificate + local HTTPS server
// ---------------------------------------------------------------------------
static NSString* SslDirPath(void) {
  NSString* docs = [NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  return [docs stringByAppendingPathComponent:@"backloop"];
}

static BOOL SslHasCert(void) {
  NSFileManager* fm = [NSFileManager defaultManager];
  NSString* dir = SslDirPath();
  return [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"cert.pem"]] &&
         [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"key.pem"]];
}

// Downloads the current *.backloop.dev wildcard cert/key from backloop.dev and
// stores them (cert+CA chain and key1+key2 concatenated) for the local HTTPS
// server. The cert is intentionally public - it only secures loopback.
static BOOL SslRefresh(NSError** errorOut) {
  NSURL* url = [NSURL URLWithString:@"https://backloop.dev/pack.json"];
  NSData* data = [NSData dataWithContentsOfURL:url
                                       options:NSDataReadingUncached
                                         error:errorOut];
  if (!data) return NO;
  NSError* jsonErr = nil;
  id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
  if (!parsed || ![parsed isKindOfClass:[NSDictionary class]]) {
    if (errorOut) *errorOut = jsonErr ?: [NSError errorWithDomain:@"ios2pd" code:1
        userInfo:@{NSLocalizedDescriptionKey : @"pack.json was not an object"}];
    return NO;
  }
  NSDictionary* pack = (NSDictionary*)parsed;
  NSString* cert = pack[@"cert"];
  NSString* ca = pack[@"ca"];
  NSString* k1 = pack[@"key1"];
  NSString* k2 = pack[@"key2"];
  if (!cert.length || !k1.length || !k2.length) {
    if (errorOut) *errorOut = [NSError errorWithDomain:@"ios2pd" code:2
        userInfo:@{NSLocalizedDescriptionKey : @"pack.json is missing cert/key fields"}];
    return NO;
  }
  NSString* bundle = ca.length ? [NSString stringWithFormat:@"%@\n%@", cert, ca]
                               : cert;
  NSString* key = [k1 stringByAppendingString:k2];
  NSFileManager* fm = [NSFileManager defaultManager];
  NSString* dir = SslDirPath();
  [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  NSError* writeErr = nil;
  BOOL ok = [bundle writeToFile:[dir stringByAppendingPathComponent:@"cert.pem"]
                     atomically:YES encoding:NSUTF8StringEncoding error:&writeErr];
  ok = ok && [key writeToFile:[dir stringByAppendingPathComponent:@"key.pem"]
                   atomically:YES encoding:NSUTF8StringEncoding error:&writeErr];
  NSDictionary* info = pack[@"info"];
  if ([info isKindOfClass:[NSDictionary class]] && info[@"notAfter"]) {
    [UD() setObject:info[@"notAfter"] forKey:kSslNotAfter];
  }
  if (!ok && errorOut) *errorOut = writeErr;
  return ok;
}

static NSString* SslNotAfterString(void) {
  NSString* v = [UD() stringForKey:kSslNotAfter];
  if (!v.length) return @"not installed";
  NSDateFormatter* f = [[NSDateFormatter alloc] init];
  f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
  f.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  NSDate* d = [f dateFromString:v];
  if (!d) return v;
  NSDateFormatter* out = [[NSDateFormatter alloc] init];
  out.dateStyle = NSDateFormatterMediumStyle;
  out.timeStyle = NSDateFormatterShortStyle;
  return [out stringFromDate:d];
}

// Builds the Wi-Fi managed payload profile that points the HTTP proxy at the
// device's own loopback via a *.backloop.dev hostname.
static NSData* MobileConfigData(NSError** errorOut) {
  NSString* host = SettingString(kBackloopHost, @"ios2pd.backloop.dev");
  int port = SettingInt(kHttpPort, 4444);
  NSMutableDictionary* wifi = [NSMutableDictionary dictionary];
  wifi[@"PayloadType"] = @"com.apple.wifi.managed";
  wifi[@"PayloadVersion"] = @1;
  wifi[@"PayloadIdentifier"] = @"org.nouvborne.ios2pd.proxy.wifi";
  wifi[@"PayloadUUID"] = [NSUUID UUID].UUIDString;
  wifi[@"PayloadDisplayName"] = @"ios2pd I2P HTTP proxy";
  wifi[@"ProxyType"] = @"Manual";
  wifi[@"ProxyServer"] = host;
  wifi[@"ProxyServerPort"] = @(port);

  NSMutableDictionary* profile = [NSMutableDictionary dictionary];
  profile[@"PayloadType"] = @"Configuration";
  profile[@"PayloadVersion"] = @1;
  profile[@"PayloadIdentifier"] = @"org.nouvborne.ios2pd.proxy";
  profile[@"PayloadUUID"] = [NSUUID UUID].UUIDString;
  profile[@"PayloadDisplayName"] = @"ios2pd I2P Proxy (backloop.dev)";
  profile[@"PayloadDescription"] =
      [NSString stringWithFormat:
          @"Sets the Wi-Fi HTTP proxy to %@:%d (resolves to this device's "
          @"loopback) so HTTP/HTTPS traffic is routed through the local i2pd "
          @"daemon running in the ios2pd app.",
          host, port];
  profile[@"PayloadContent"] = @[ wifi ];
  return [NSPropertyListSerialization dataWithPropertyList:profile
                                                    format:NSPropertyListXMLFormat_v1_0
                                                   options:0
                                                     error:errorOut];
}

static NSData* HomeHtmlData(void) {
  NSString* host = SettingString(kBackloopHost, @"ios2pd.backloop.dev");
  int port = SettingInt(kHttpPort, 4444);
  NSString* html = [NSString stringWithFormat:
      @"<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" "
      @"content=\"width=device-width\"><title>ios2pd</title></head><body>"
      @"<h2>ios2pd local server</h2>"
      @"<p>This HTTPS server runs on this device (loopback via backloop.dev).</p>"
      @"<p><a href=\"/install.mobileconfig\">Install the I2P proxy profile</a></p>"
      @"<p>Proxy: <code>%@</code>:<code>%d</code></p>"
      @"<p>Start i2pd in the app, then browse <code>*.i2p</code> sites in Safari.</p>"
      @"</body></html>", host, port];
  return [html dataUsingEncoding:NSUTF8StringEncoding];
}

static std::atomic<bool> gSslStop{false};
static std::thread gSslThread;

// Handles one accepted connection: TLS handshake, then serves /install.mobileconfig.
static void HandleClient(int c) {
  NSString* dir = SslDirPath();
  SSL_CTX* ctx = SSL_CTX_new(TLS_server_method());
  if (!ctx) { close(c); return; }
  SSL_CTX_set_options(ctx, SSL_OP_NO_SSLv2 | SSL_OP_NO_SSLv3 | SSL_OP_NO_TLSv1 |
                               SSL_OP_NO_TLSv1_1);
  if (SSL_CTX_use_certificate_chain_file(
          ctx, [[dir stringByAppendingPathComponent:@"cert.pem"] UTF8String]) != 1 ||
      SSL_CTX_use_PrivateKey_file(
          ctx, [[dir stringByAppendingPathComponent:@"key.pem"] UTF8String],
          SSL_FILETYPE_PEM) != 1) {
    SSL_CTX_free(ctx);
    close(c);
    return;
  }
  SSL* ssl = SSL_new(ctx);
  if (!ssl) { SSL_CTX_free(ctx); close(c); return; }
  SSL_set_fd(ssl, c);
  if (SSL_accept(ssl) != 1) {
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    close(c);
    return;
  }
  char buf[16384];
  int n = SSL_read(ssl, buf, sizeof(buf) - 1);
  if (n > 0) {
    buf[n] = 0;
    std::string req(buf, n);
    std::string path = "/";
    size_t sp = req.find(' ');
    if (sp != std::string::npos) {
      size_t sp2 = req.find(' ', sp + 1);
      if (sp2 != std::string::npos) path = req.substr(sp + 1, sp2 - sp - 1);
    }
    NSData* body = nil;
    NSString* ctype = @"text/html; charset=utf-8";
    if (path == "/install.mobileconfig") {
      NSError* e = nil;
      body = MobileConfigData(&e);
      if (!body) body = [@"" dataUsingEncoding:NSUTF8StringEncoding];
      ctype = @"application/x-apple-aspen-config";
    } else {
      body = HomeHtmlData();
    }
    std::string resp = "HTTP/1.1 200 OK\r\n"
                       "Content-Type: " + std::string(ctype.UTF8String) + "\r\n"
                       "Content-Length: " + std::to_string(body.length) + "\r\n"
                       "Connection: close\r\n"
                       "\r\n";
    SSL_write(ssl, resp.data(), resp.size());
    SSL_write(ssl, body.bytes, body.length);
  }
  SSL_free(ssl);
  SSL_CTX_free(ctx);
  close(c);
}

static void SslServerLoop(int port) {
  if (!SslHasCert()) return;
  int sock = socket(AF_INET, SOCK_STREAM, 0);
  if (sock < 0) return;
  int one = 1;
  setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(sock, (struct sockaddr*)&addr, sizeof(addr)) != 0 ||
      listen(sock, 4) != 0) {
    close(sock);
    return;
  }
  while (!gSslStop.load()) {
    struct pollfd pfd;
    pfd.fd = sock;
    pfd.events = POLLIN;
    pfd.revents = 0;
    int pr = poll(&pfd, 1, 250);
    if (pr <= 0) continue;
    int c = accept(sock, nullptr, nullptr);
    if (c >= 0) HandleClient(c);
  }
  close(sock);
}

static void SslServerStart(int port) {
  if (gSslThread.joinable()) {
    gSslStop.store(true);
    gSslThread.join();
  }
  gSslStop.store(false);
  gSslThread = std::thread([port]() { SslServerLoop(port); });
}

// ---------------------------------------------------------------------------
// Router tab
// ---------------------------------------------------------------------------
@interface RouterViewController : UIViewController
@end

@implementation RouterViewController {
  UILabel* _status;
  UILabel* _vpn;
  UIButton* _toggle;
  UITextView* _log;
  NSTimer* _timer;
}

- (void)viewDidLoad {
  [super viewDidLoad];

  self.view.backgroundColor = [UIColor systemBackgroundColor];
  self.navigationItem.title = @"Router";
  CGRect bounds = self.view.bounds;

  _status = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, bounds.size.width - 32, 24)];
  _status.text = @"i2pd: stopped";
  _status.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
  _status.textColor = [UIColor labelColor];
  _status.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  [self.view addSubview:_status];

  _toggle = [UIButton buttonWithType:UIButtonTypeSystem];
  _toggle.frame = CGRectMake(16, 36, bounds.size.width - 32, 44);
  [_toggle setTitle:@"Start" forState:UIControlStateNormal];
  [_toggle setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  _toggle.backgroundColor = [UIColor systemBlueColor];
  _toggle.layer.cornerRadius = 10;
  [_toggle addTarget:self action:@selector(onToggle:) forControlEvents:UIControlEventTouchUpInside];
  _toggle.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  [self.view addSubview:_toggle];

  _vpn = [[UILabel alloc] initWithFrame:CGRectMake(16, 88, bounds.size.width - 32, 24)];
  _vpn.text = @"VPN: not configured — enable in Settings > VPN";
  _vpn.font = [UIFont systemFontOfSize:13];
  _vpn.textColor = [UIColor secondaryLabelColor];
  _vpn.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  [self.view addSubview:_vpn];

  CGFloat y = 120;
  _log = [[UITextView alloc] initWithFrame:CGRectMake(8, y, bounds.size.width - 16, bounds.size.height - y - 8)];
  _log.editable = NO;
  _log.selectable = YES;
  _log.font = [UIFont fontWithName:@"Menlo" size:11];
  _log.textColor = [UIColor labelColor];
  _log.backgroundColor = [UIColor secondarySystemBackgroundColor];
  _log.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:_log];

  _timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                            target:self
                                          selector:@selector(refreshLog)
                                          userInfo:nil
                                           repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  if ([self isMovingFromParentViewController] || self.tabBarController == nil) {
    [_timer invalidate];
  }
}

- (void)onToggle:(id)sender {
  if (gStarted.load()) {
    StopDaemon();
    _status.text = @"i2pd: stopped";
    [_toggle setTitle:@"Start" forState:UIControlStateNormal];
  } else {
    if (StartDaemon()) {
      _status.text = @"i2pd: starting...";
      [_toggle setTitle:@"Stop" forState:UIControlStateNormal];
      InstallVpnProfile();
    } else {
      _status.text = @"i2pd: failed to start";
    }
  }
}

- (void)refreshLog {
  std::string text = TakeLog();
  if (!text.empty()) {
    NSString* s = [NSString stringWithUTF8String:text.c_str()];
    if (![_log.text isEqualToString:s]) {
      _log.text = s;
      [_log scrollRangeToVisible:NSMakeRange(_log.text.length - 1, 1)];
    }
  }
  if (gStarted.load()) {
    _status.text = @"i2pd: running";
  }
  _vpn.text = [NSString stringWithFormat:@"VPN: %@ — toggle in Settings > VPN",
                                         VpnStatusString()];
}

@end

// ---------------------------------------------------------------------------
// i2pd settings tab
// ---------------------------------------------------------------------------
@interface I2pdSettingsViewController : UITableViewController <UITextFieldDelegate>
@end

@implementation I2pdSettingsViewController

- (instancetype)init {
  self = [super initWithStyle:UITableViewStyleGrouped];
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.navigationItem.title = @"i2pd";
  self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
  return 4;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  switch (section) {
    case 0: return 2;  // HTTP proxy
    case 1: return 2;  // SOCKS proxy
    case 2: return 2;  // SAM
    case 3: return 1;  // log level
    default: return 0;
  }
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
  switch (section) {
    case 0: return @"HTTP proxy (browsers)";
    case 1: return @"SOCKS5 proxy";
    case 2: return @"SAM";
    case 3: return @"Logging";
    default: return nil;
  }
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  switch (section) {
    case 0: return @"Used by the Wi-Fi proxy profile and by browsers on this device.";
    case 1: return @"Used by the optional VPN extension to tunnel *.i2p flows.";
    case 3: return @"Changes apply the next time you start the router.";
    default: return nil;
  }
}

- (UITextField*)portFieldWithTag:(NSInteger)tag value:(NSInteger)value {
  UITextField* f = [[UITextField alloc] initWithFrame:CGRectZero];
  f.tag = 1000 + ((tag - 100) / 10);
  f.text = [NSString stringWithFormat:@"%ld", (long)value];
  f.keyboardType = UIKeyboardTypeNumberPad;
  f.textAlignment = NSTextAlignmentRight;
  f.returnKeyType = UIReturnKeyDone;
  f.delegate = self;
  return f;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)ip {
  NSInteger section = ip.section;
  NSInteger row = ip.row;
  BOOL isSwitch = (row == 0);
  NSString* title;
  if (isSwitch) {
    switch (section) {
      case 0: title = @"Enabled"; break;
      case 1: title = @"Enabled"; break;
      case 2: title = @"Enabled"; break;
      default: title = @""; break;
    }
  } else {
    switch (section) {
      case 0: title = @"Port"; break;
      case 1: title = @"Port"; break;
      case 2: title = @"Port"; break;
      default: title = @""; break;
    }
  }
  NSString* cellId = isSwitch ? @"sw" : @"txt";
  UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:cellId];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
  }
  cell.textLabel.text = title;
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  cell.accessoryView = nil;
  for (UIView* sub in cell.contentView.subviews) {
    if ([sub isKindOfClass:[UITextField class]]) [sub removeFromSuperview];
  }

  if (section == 3) {
    // Log level segmented control
    cell.textLabel.text = @"Level";
    UISegmentedControl* seg = [[UISegmentedControl alloc] initWithItems:@[ @"info", @"debug", @"warn", @"error" ]];
    seg.frame = CGRectMake(0, 0, 220, 30);
    NSString* lvl = SettingString(kLogLevel, @"info");
    seg.selectedSegmentIndex = [@[ @"info", @"debug", @"warn", @"error" ] indexOfObject:lvl];
    if (seg.selectedSegmentIndex == NSNotFound) seg.selectedSegmentIndex = 0;
    [seg addTarget:self action:@selector(logLevelChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = seg;
    return cell;
  }

  NSInteger tag = section * 10 + row + 100;
  if (isSwitch) {
    UISwitch* sw = [[UISwitch alloc] init];
    sw.tag = tag;
    BOOL on = NO;
    if (section == 0) on = SettingBool(kHttpOn, YES);
    else if (section == 1) on = SettingBool(kSocksOn, YES);
    else if (section == 2) on = SettingBool(kSamOn, YES);
    sw.on = on;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
  } else {
    int value = 0;
    if (section == 0) value = SettingInt(kHttpPort, 4444);
    else if (section == 1) value = SettingInt(kSocksPort, 4447);
    else if (section == 2) value = SettingInt(kSamPort, 7656);
    UITextField* f = [self portFieldWithTag:tag value:value];
    CGFloat w = self.tableView.bounds.size.width - 130;
    f.frame = CGRectMake(w, 7, 100, 30);
    f.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [cell.contentView addSubview:f];
  }
  return cell;
}

- (void)switchChanged:(UISwitch*)sw {
  NSInteger section = (sw.tag - 100) / 10;
  switch (section) {
    case 0: [UD() setBool:sw.on forKey:kHttpOn]; break;
    case 1: [UD() setBool:sw.on forKey:kSocksOn]; break;
    case 2: [UD() setBool:sw.on forKey:kSamOn]; break;
  }
}

- (void)logLevelChanged:(UISegmentedControl*)seg {
  NSArray* levels = @[ @"info", @"debug", @"warn", @"error" ];
  NSInteger i = seg.selectedSegmentIndex;
  [UD() setObject:(i >= 0 && i < levels.count) ? levels[i] : @"info" forKey:kLogLevel];
}

- (void)textFieldDidEndEditing:(UITextField*)field {
  NSInteger section = field.tag - 1000;
  int port = [field.text intValue];
  if (port < 1 || port > 65535) {
    int def = (section == 0) ? 4444 : (section == 1) ? 4447 : 7656;
    port = def;
    field.text = [NSString stringWithFormat:@"%d", port];
  }
  NSString* key = (section == 0) ? kHttpPort : (section == 1) ? kSocksPort : kSamPort;
  [UD() setInteger:port forKey:key];
}

- (BOOL)textFieldShouldReturn:(UITextField*)field {
  [field resignFirstResponder];
  return YES;
}

@end

// ---------------------------------------------------------------------------
// Proxy / app settings tab
// ---------------------------------------------------------------------------
@interface AppSettingsViewController : UITableViewController <UITextFieldDelegate>
@property (nonatomic, assign) BOOL busy;
@end

@implementation AppSettingsViewController

- (instancetype)init {
  self = [super initWithStyle:UITableViewStyleGrouped];
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.navigationItem.title = @"Proxy";
  self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
  return 3;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  switch (section) {
    case 0: return 4;  // host, port, ssl status, update
    case 1: return 1;  // install profile
    case 2: return 1;  // keep alive
    default: return 0;
  }
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
  switch (section) {
    case 0: return @"backloop.dev";
    case 1: return @"Proxy profile";
    case 2: return @"General";
    default: return nil;
  }
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  switch (section) {
    case 0:
      return @"backloop.dev is a wildcard domain pointing at 127.0.0.1 with a "
             @"publicly trusted certificate. The app serves HTTPS on this "
             @"device so Safari can install the profile over a trusted link.";
    case 1:
      return @"Installs a Wi-Fi profile that routes HTTP/HTTPS through the "
             @"local i2pd proxy (start the router first). Requires Wi-Fi; "
             @"i2pd must keep running while you browse.";
    case 2:
      return @"Without keep-alive, iOS suspends the app and the proxy stops. "
             @"Keep-alive plays silent audio so i2pd stays up in the "
             @"background (battery impact).";
    default: return nil;
  }
}

- (void)updateBusy:(BOOL)busy {
  self.busy = busy;
  [self.tableView reloadRowsAtIndexPaths:@[
    [NSIndexPath indexPathForRow:2 inSection:0],
    [NSIndexPath indexPathForRow:3 inSection:0],
    [NSIndexPath indexPathForRow:0 inSection:1],
  ]
                        withRowAnimation:UITableViewRowAnimationNone];
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)ip {
  NSString* cellId = [NSString stringWithFormat:@"c%ld-%ld", (long)ip.section, (long)ip.row];
  UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:cellId];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellId];
  }
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  cell.accessoryView = nil;
  cell.accessoryType = UITableViewCellAccessoryNone;
  cell.textLabel.text = @"";
  cell.detailTextLabel.text = @"";
  [[cell.contentView viewWithTag:2000] removeFromSuperview];

  if (ip.section == 0) {
    switch (ip.row) {
      case 0: {
        cell.textLabel.text = @"Hostname";
        UITextField* f = [[UITextField alloc] initWithFrame:CGRectZero];
        f.tag = 2000;
        f.text = SettingString(kBackloopHost, @"ios2pd.backloop.dev");
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.keyboardType = UIKeyboardTypeURL;
        f.returnKeyType = UIReturnKeyDone;
        f.delegate = self;
        CGFloat w = self.tableView.bounds.size.width - 150;
        f.frame = CGRectMake(w, 7, 120, 30);
        f.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [cell.contentView addSubview:f];
        break;
      }
      case 1: {
        cell.textLabel.text = @"HTTPS port";
        UITextField* f = [[UITextField alloc] initWithFrame:CGRectZero];
        f.tag = 2000;
        f.text = [NSString stringWithFormat:@"%d", SettingInt(kBackloopPort, 8443)];
        f.keyboardType = UIKeyboardTypeNumberPad;
        f.textAlignment = NSTextAlignmentRight;
        f.returnKeyType = UIReturnKeyDone;
        f.delegate = self;
        CGFloat w = self.tableView.bounds.size.width - 150;
        f.frame = CGRectMake(w, 7, 120, 30);
        f.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [cell.contentView addSubview:f];
        break;
      }
      case 2: {
        cell.textLabel.text = @"SSL certificate valid until";
        cell.detailTextLabel.text = self.busy ? @"updating…" : SslNotAfterString();
        break;
      }
      case 3: {
        cell.textLabel.text = @"Update SSL servers";
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.accessoryType = self.busy ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
        if (self.busy) {
          UIActivityIndicatorView* spin =
              [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
          [spin startAnimating];
          cell.accessoryView = spin;
        }
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        break;
      }
    }
  } else if (ip.section == 1) {
    cell.textLabel.text = @"Install proxy profile (.mobileconfig)";
    cell.textLabel.textColor = [UIColor systemBlueColor];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    if (self.busy) {
      UIActivityIndicatorView* spin =
          [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
      [spin startAnimating];
      cell.accessoryView = spin;
    }
  } else if (ip.section == 2) {
    cell.textLabel.text = @"Keep i2pd alive in background";
    UISwitch* sw = [[UISwitch alloc] init];
    sw.tag = 3000;
    sw.on = SettingBool(kKeepAlive, NO);
    [sw addTarget:self action:@selector(keepAliveChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
  }
  return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)ip {
  if (ip.section == 0 && ip.row == 3) {
    [self updateSslServers];
  } else if (ip.section == 1) {
    [self installProfile];
  }
  [tableView deselectRowAtIndexPath:ip animated:YES];
}

- (void)keepAliveChanged:(UISwitch*)sw {
  [UD() setBool:sw.on forKey:kKeepAlive];
  [[KeepAlive shared] apply];
}

- (void)textFieldDidEndEditing:(UITextField*)field {
  UIView* v = field;
  while (v && ![v isKindOfClass:[UITableViewCell class]]) v = v.superview;
  NSIndexPath* ip = v ? [self.tableView indexPathForCell:(UITableViewCell*)v] : nil;
  if (ip.section == 0) {
    if (ip.row == 0) {
      NSString* h = [field.text stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceCharacterSet]];
      if (!h.length) h = @"ios2pd.backloop.dev";
      field.text = h;
      [UD() setObject:h forKey:kBackloopHost];
    } else if (ip.row == 1) {
      int port = [field.text intValue];
      if (port < 1 || port > 65535) port = 8443;
      field.text = [NSString stringWithFormat:@"%d", port];
      [UD() setInteger:port forKey:kBackloopPort];
    }
  }
}

- (BOOL)textFieldShouldReturn:(UITextField*)field {
  [field resignFirstResponder];
  return YES;
}

- (void)alert:(NSString*)message {
  UIAlertController* a = [UIAlertController alertControllerWithTitle:@"ios2pd"
                                                              message:message
                                                       preferredStyle:UIAlertControllerStyleAlert];
  [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
  [self presentViewController:a animated:YES completion:nil];
}

- (void)updateSslServers {
  [self updateBusy:YES];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError* e = nil;
    BOOL ok = SslRefresh(&e);
    dispatch_async(dispatch_get_main_queue(), ^{
      [self updateBusy:NO];
      [self alert:ok ? @"SSL certificate updated from backloop.dev."
                     : [NSString stringWithFormat:@"Update failed: %@",
                                                   e.localizedDescription ?: @"unknown error"]];
    });
  });
}

- (void)doInstall {
  int port = SettingInt(kBackloopPort, 8443);
  NSString* host = SettingString(kBackloopHost, @"ios2pd.backloop.dev");
  SslServerStart(port);
  NSString* url = [NSString stringWithFormat:@"https://%@:%d/install.mobileconfig", host, port];
  [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url]
                                     options:@{}
                           completionHandler:^(BOOL ok) {
                             if (!ok) {
                               [self alert:
                                   @"Could not open Safari. Make sure the app is "
                                   @"running and Wi-Fi is available."];
                             }
                           }];
}

- (void)installProfile {
  if (self.busy) return;
  if (!SslHasCert()) {
    [self updateBusy:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSError* e = nil;
      BOOL ok = SslRefresh(&e);
      dispatch_async(dispatch_get_main_queue(), ^{
        [self updateBusy:NO];
        if (!ok) {
          [self alert:[NSString stringWithFormat:@"SSL setup failed: %@",
                                                 e.localizedDescription ?: @"unknown error"]];
          return;
        }
        [self doInstall];
      });
    });
  } else {
    [self doInstall];
  }
}

@end

// ---------------------------------------------------------------------------
// App delegate
// ---------------------------------------------------------------------------
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow* window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  [[KeepAlive shared] apply];

  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

  RouterViewController* router = [[RouterViewController alloc] init];
  router.title = @"Router";
  router.tabBarItem.image = [UIImage systemImageNamed:@"network"];

  I2pdSettingsViewController* i2pd = [[I2pdSettingsViewController alloc] init];
  i2pd.title = @"i2pd";
  i2pd.tabBarItem.image = [UIImage systemImageNamed:@"switch.2"];

  AppSettingsViewController* proxy = [[AppSettingsViewController alloc] init];
  proxy.title = @"Proxy";
  proxy.tabBarItem.image = [UIImage systemImageNamed:@"globe"];

  UINavigationController* n1 = [[UINavigationController alloc] initWithRootViewController:router];
  UINavigationController* n2 = [[UINavigationController alloc] initWithRootViewController:i2pd];
  UINavigationController* n3 = [[UINavigationController alloc] initWithRootViewController:proxy];

  UITabBarController* tbc = [[UITabBarController alloc] init];
  tbc.viewControllers = @[ n1, n2, n3 ];

  self.window.rootViewController = tbc;
  [self.window makeKeyAndVisible];
  return YES;
}

- (void)applicationWillTerminate:(UIApplication*)application {
  StopDaemon();
}

- (void)applicationDidEnterBackground:(UIApplication*)application {
  [[KeepAlive shared] apply];
}

- (void)applicationDidBecomeActive:(UIApplication*)application {
  [[KeepAlive shared] apply];
}

@end

int main(int argc, char* argv[]) {
  @autoreleasepool {
    OPENSSL_init_ssl(0, NULL);
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
  }
}

//
//  ios2pd — i2pd (I2P daemon) as an iOS app.
//
//  Links the i2pd C++ daemon core (DaemonUnix) into a small UIKit shell.
//  The router runs on a background thread; logs are captured through a
//  custom std::ostream and surfaced in the UI.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>

#include <atomic>
#include <mutex>
#include <ostream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "Daemon.h"
#include "Log.h"
#include "Config.h"
#include "FS.h"

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
      "--loglevel=info",
      "--log=stdout",
      "--httpproxy.enabled=true",
      "--httpproxy.port=4444",
      "--socksproxy.enabled=true",
      "--socksproxy.port=4447",
      "--sam.enabled=true",
      "--sam.port=7656",
  };
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
      @"proxyPort" : @4447,
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
}

}  // namespace

// ---------------------------------------------------------------------------
// UI
// ---------------------------------------------------------------------------
@interface ViewController : UIViewController
@end

@implementation ViewController {
  UILabel* _status;
  UILabel* _vpn;
  UIButton* _toggle;
  UITextView* _log;
  NSTimer* _timer;
}

- (void)viewDidLoad {
  [super viewDidLoad];

  self.view.backgroundColor = [UIColor systemBackgroundColor];
  CGRect bounds = self.view.bounds;

  _status = [[UILabel alloc] initWithFrame:CGRectMake(16, 70, bounds.size.width - 32, 24)];
  _status.text = @"i2pd: stopped";
  _status.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
  _status.textColor = [UIColor labelColor];
  _status.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  [self.view addSubview:_status];

  _toggle = [UIButton buttonWithType:UIButtonTypeSystem];
  _toggle.frame = CGRectMake(16, 96, bounds.size.width - 32, 44);
  [_toggle setTitle:@"Start" forState:UIControlStateNormal];
  [_toggle setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  _toggle.backgroundColor = [UIColor systemBlueColor];
  _toggle.layer.cornerRadius = 10;
  [_toggle addTarget:self action:@selector(onToggle:) forControlEvents:UIControlEventTouchUpInside];
  _toggle.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  [self.view addSubview:_toggle];

  _vpn = [[UILabel alloc] initWithFrame:CGRectMake(16, 148, bounds.size.width - 32, 24)];
  _vpn.text = @"VPN: not configured — enable in Settings > VPN";
  _vpn.font = [UIFont systemFontOfSize:13];
  _vpn.textColor = [UIColor secondaryLabelColor];
  _vpn.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  [self.view addSubview:_vpn];

  CGFloat y = 182;
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

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow* window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  self.window.rootViewController = [[ViewController alloc] init];
  [self.window makeKeyAndVisible];
  return YES;
}

- (void)applicationWillTerminate:(UIApplication*)application {
  StopDaemon();
}

@end

int main(int argc, char* argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
  }
}

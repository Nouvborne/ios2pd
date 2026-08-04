#import <NetworkExtension/NetworkExtension.h>

// NEAppProxyProvider for ios2pd.
//
// When the user enables the "ios2pd I2P VPN" in Settings, this extension:
//   * answers DNS queries for *.i2p with fake IPs inside 10.192.0.0/10,
//   * forwards TCP flows to those fake IPs to the local i2pd SOCKS5 proxy
//     (127.0.0.1:4447), which resolves and tunnels to the I2P destination,
//   * forwards everything else directly (clearnet still works).
@interface AppProxyProvider : NEAppProxyProvider
@end

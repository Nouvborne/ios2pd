#import <NetworkExtension/NetworkExtension.h>

// Packet-tunnel provider for ios2pd.
//
// The i2pd router runs inside this extension rather than inside the app, so it
// keeps running once the app is backgrounded and suspended. The tunnel itself
// carries no packets: it exists to publish the router's local HTTP proxy to the
// whole system through the tunnel's proxy settings, scoped to *.i2p. Clearnet
// traffic is never captured.
@interface PacketTunnelProvider : NEPacketTunnelProvider
@end

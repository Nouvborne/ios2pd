#import "AppProxyProvider.h"

#import <arpa/inet.h>
#import <netdb.h>
#import <netinet/in.h>
#import <pthread.h>
#import <sys/socket.h>
#import <sys/types.h>

#import <Network/Network.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define FAKE_NET_BASE 0x0AC00000u  // 10.192.0.0
#define FAKE_NET_COUNT (1u << 22)  // /10 -> 10.192.0.0 - 10.255.255.255

// ---------------------------------------------------------------------------
// name <-> fake-IP mapping
// ---------------------------------------------------------------------------

static NSMutableDictionary<NSNumber*, NSString*> *gIpToName;
static NSMutableDictionary<NSString*, NSNumber*> *gNameToIp;
static pthread_mutex_t gMapLock = PTHREAD_MUTEX_INITIALIZER;

static uint32_t ipv4ToUint(NSString* s) {
  const char* c = s.UTF8String;
  if (!c) return 0;
  struct in_addr a;
  if (inet_aton(c, &a) == 1) return ntohl(a.s_addr);
  return 0;
}

static uint32_t fnv1a(const char* s) {
  uint32_t h = 2166136261u;
  for (; *s; ++s) {
    h ^= (unsigned char)(*s | 0x20);
    h *= 16777619u;
  }
  return h;
}

static NSString* normalizeHost(NSString* host) {
  NSMutableString* m = [host.lowercaseString mutableCopy];
  while ([m hasSuffix:@"."]) m = [[m substringToIndex:m.length - 1] mutableCopy];
  return m;
}

static BOOL isI2pName(NSString* name) {
  return [name isEqualToString:@"i2p"] || [name hasSuffix:@".i2p"];
}

static uint32_t fakeIpForName(NSString* name) {
  return FAKE_NET_BASE + (fnv1a(name.UTF8String) % FAKE_NET_COUNT);
}

static NSString* nameForIp(uint32_t ip) {
  pthread_mutex_lock(&gMapLock);
  NSString* n = gIpToName[@(ip)];
  pthread_mutex_unlock(&gMapLock);
  return n;
}

static void mapName(NSString* name, uint32_t ip) {
  pthread_mutex_lock(&gMapLock);
  if (!gIpToName) {
    gIpToName = [NSMutableDictionary new];
    gNameToIp = [NSMutableDictionary new];
  }
  if (gIpToName[@(ip)] == nil) {
    gIpToName[@(ip)] = name;
    gNameToIp[name] = @(ip);
  }
  pthread_mutex_unlock(&gMapLock);
}

// ---------------------------------------------------------------------------
// DNS (fake DNS server answering *.i2p with an A record in 10.192.0.0/10)
// ---------------------------------------------------------------------------

// Decodes a (possibly compressed) DNS name. Returns the offset just past the
// question name in the original message, or -1 on failure.
static int dnsParseName(const uint8_t* msg, int msglen, int p, NSMutableString* out) {
  int pos = -1;
  int hops = 0;
  for (;;) {
    if (p >= msglen) return -1;
    uint8_t len = msg[p];
    if ((len & 0xC0) == 0xC0) {
      if (p + 1 >= msglen) return -1;
      if (pos < 0) pos = p + 2;
      p = ((len & 0x3F) << 8) | msg[p + 1];
      if (++hops > 128) return -1;
      continue;
    }
    if (len == 0) {
      if (pos < 0) pos = p + 1;
      break;
    }
    if (p + 1 + len > msglen) return -1;
    if (out.length) [out appendString:@"."];
    [out appendString:
         [[NSString alloc] initWithBytes:msg + p + 1 length:len encoding:NSASCIIStringEncoding]];
    p += 1 + len;
  }
  return pos;
}

static uint16_t qclassOf(const uint8_t* q, int offset) {
  return (uint16_t)((q[offset + 2] << 8) | q[offset + 3]);
}

static NSData* buildDnsResponse(NSData* query) {
  const uint8_t* q = query.bytes;
  NSUInteger ql = query.length;
  if (ql < 12) return nil;
  uint16_t idv = (uint16_t)((q[0] << 8) | q[1]);
  uint16_t qd = (uint16_t)((q[4] << 8) | q[5]);
  if (qd == 0) return nil;

  NSMutableString* name = [NSMutableString new];
  int afterQ = dnsParseName(q, (int)ql, 12, name);
  if (afterQ < 0 || afterQ + 4 > (int)ql) return nil;
  uint16_t qtype = (uint16_t)((q[afterQ] << 8) | q[afterQ + 1]);
  if (qclassOf(q, afterQ) != 1) return nil;  // only IN class

  NSString* n = normalizeHost(name);
  if (!isI2pName(n)) return nil;

  uint16_t rcode = 0;
  uint16_t ancount = 0;
  uint8_t rdata[4];
  if (qtype == 1) {  // A
    uint32_t ip = fakeIpForName(n);
    mapName(n, ip);
    rdata[0] = (uint8_t)(ip >> 24);
    rdata[1] = (uint8_t)(ip >> 16);
    rdata[2] = (uint8_t)(ip >> 8);
    rdata[3] = (uint8_t)ip;
    ancount = 1;
  } else if (qtype == 28) {  // AAAA: NOERROR, zero answers -> clients retry A
  } else {
    rcode = 3;  // NXDOMAIN
  }

  NSMutableData* resp = [NSMutableData dataWithCapacity:ql + 32];
  uint16_t flags = (uint16_t)(0x8180 | rcode);  // QR RD RA
  uint8_t hdr[12];
  hdr[0] = (uint8_t)(idv >> 8);
  hdr[1] = (uint8_t)(idv & 0xff);
  hdr[2] = (uint8_t)(flags >> 8);
  hdr[3] = (uint8_t)(flags & 0xff);
  hdr[4] = 0;
  hdr[5] = 1;  // qdcount
  hdr[6] = (uint8_t)(ancount >> 8);
  hdr[7] = (uint8_t)(ancount & 0xff);
  hdr[8] = 0;
  hdr[9] = 0;
  hdr[10] = 0;
  hdr[11] = 0;
  [resp appendBytes:hdr length:12];
  [resp appendBytes:q + 12 length:(NSUInteger)(afterQ - 12)];  // question name
  [resp appendBytes:q + afterQ length:4];                      // qtype + qclass
  if (ancount) {
    uint8_t an[12];
    an[0] = 0xC0;  // pointer to qname at offset 12
    an[1] = 0x0C;
    an[2] = 0;
    an[3] = 1;  // A
    an[4] = 0;
    an[5] = 1;  // IN
    an[6] = 0;
    an[7] = 0;
    an[8] = 0;
    an[9] = 60;  // TTL 60
    an[10] = 0;
    an[11] = 4;  // rdlen
    [resp appendBytes:an length:12];
    [resp appendBytes:rdata length:4];
  }
  return resp;
}

// ---------------------------------------------------------------------------
// Socket helpers
// ---------------------------------------------------------------------------

static int sendAll(int fd, const void* buf, size_t n) {
  const char* p = buf;
  while (n > 0) {
    ssize_t w = send(fd, p, n, 0);
    if (w < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    p += w;
    n -= (size_t)w;
  }
  return 0;
}

static int recvFull(int fd, void* buf, size_t n) {
  char* p = buf;
  while (n > 0) {
    ssize_t r = recv(fd, p, n, 0);
    if (r <= 0) {
      if (r < 0 && errno == EINTR) continue;
      return -1;
    }
    p += r;
    n -= (size_t)r;
  }
  return 0;
}

// SOCKS5 no-auth CONNECT to host:port over the already-open fd.
static int socksHandshake(int fd, NSString* host, uint16_t port) {
  const uint8_t greet[3] = {5, 1, 0};
  if (sendAll(fd, greet, 3) != 0) return -1;
  uint8_t auth[2];
  if (recvFull(fd, auth, 2) != 0 || auth[0] != 5 || auth[1] != 0) return -1;

  const char* h = host.UTF8String ?: "";
  size_t hl = strlen(h);
  if (hl > 255) hl = 255;
  uint8_t req[4 + 1 + 255 + 2];
  size_t off = 0;
  req[off++] = 5;
  req[off++] = 1;
  req[off++] = 0;
  req[off++] = 3;  // domain name
  req[off++] = (uint8_t)hl;
  memcpy(req + off, h, hl);
  off += hl;
  req[off++] = (uint8_t)(port >> 8);
  req[off++] = (uint8_t)(port & 0xff);
  if (sendAll(fd, req, off) != 0) return -1;

  uint8_t hdr[4];
  if (recvFull(fd, hdr, 4) != 0 || hdr[0] != 5 || hdr[1] != 0) return -1;
  if (hdr[3] == 1) {
    uint8_t rest[6];
    if (recvFull(fd, rest, 6) != 0) return -1;
  } else if (hdr[3] == 3) {
    uint8_t len;
    if (recvFull(fd, &len, 1) != 0) return -1;
    uint8_t rest[256];
    if (recvFull(fd, rest, len) != 0) return -1;
    uint8_t pp[2];
    if (recvFull(fd, pp, 2) != 0) return -1;
  } else if (hdr[3] == 4) {
    uint8_t rest[18];
    if (recvFull(fd, rest, 18) != 0) return -1;
  }
  return 0;
}

// Opens a socket. If socks=YES, connects to socksHost:socksPort and CONNECTs
// to host:port over it; otherwise connects to host:port directly.
static int openSocket(NSString* host,
                      uint16_t port,
                      BOOL socks,
                      NSString* socksHost,
                      uint16_t socksPort) {
  struct addrinfo hints, *res = NULL;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  const char* targetHost = socks ? socksHost.UTF8String : host.UTF8String;
  uint16_t targetPort = socks ? socksPort : port;
  char portstr[8];
  snprintf(portstr, sizeof(portstr), "%u", (unsigned)targetPort);
  if (getaddrinfo(targetHost, portstr, &hints, &res) != 0) return -1;

  int fd = -1;
  for (struct addrinfo* ai = res; ai; ai = ai->ai_next) {
    fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (fd < 0) continue;
    if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
    close(fd);
    fd = -1;
  }
  freeaddrinfo(res);
  if (fd < 0) return -1;

  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

  if (socks && socksHandshake(fd, host, port) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

// ---------------------------------------------------------------------------
// TCP relay
// ---------------------------------------------------------------------------

@interface Relay : NSObject
- (instancetype)initWithFlow:(NEAppProxyTCPFlow*)flow
                        host:(NSString*)host
                        port:(uint16_t)port
                   socksHost:(NSString*)socksHost
                   socksPort:(uint16_t)socksPort
                      direct:(BOOL)direct;
@property(nonatomic, copy) void (^onDone)(void);
- (void)start;
@end

@implementation Relay {
  NEAppProxyTCPFlow* _flow;
  NSString* _host;
  uint16_t _port;
  NSString* _socksHost;
  uint16_t _socksPort;
  BOOL _direct;
  int _fd;
  dispatch_queue_t _q;
  volatile BOOL _done;
}

- (instancetype)initWithFlow:(NEAppProxyTCPFlow*)flow
                        host:(NSString*)host
                        port:(uint16_t)port
                   socksHost:(NSString*)socksHost
                   socksPort:(uint16_t)socksPort
                      direct:(BOOL)direct {
  if ((self = [super init])) {
    _flow = flow;
    _host = host;
    _port = port;
    _socksHost = socksHost;
    _socksPort = socksPort;
    _direct = direct;
    _fd = -1;
    _q = dispatch_queue_create("ios2pd.relay", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)start {
  dispatch_async(_q, ^{
    _fd = openSocket(_host, _port, !_direct, _socksHost, _socksPort);
    if (_fd < 0) {
      NSLog(@"[ios2pd] relay connect %@:%u failed", _host, _port);
      [self finish];
      return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      [self sockToFlowLoop];
    });
    [self readNext];
  });
}

- (void)sockToFlowLoop {
  uint8_t buf[32768];
  for (;;) {
    if (_done) break;
    ssize_t n = recv(_fd, buf, sizeof(buf), 0);
    if (_done) break;
    if (n > 0) {
      NSData* d = [NSData dataWithBytes:buf length:(NSUInteger)n];
      dispatch_async(_q, ^{
        if (_done) return;
        __weak Relay* weakSelf = self;
        [_flow writeData:d
           withCompletionHandler:^(NSError* e) {
             if (e) [weakSelf finish];
           }];
      });
    } else if (n == 0) {
      dispatch_async(_q, ^{
        if (!_done) [_flow closeWriteWithError:nil];
      });
      break;
    } else if (errno != EINTR) {
      dispatch_async(_q, ^{
        if (!_done) [self finish];
      });
      break;
    }
  }
}

- (void)readNext {
  if (_done) return;
  __weak Relay* weakSelf = self;
  [_flow readDataWithCompletionHandler:^(NSData* data, NSError* err) {
    Relay* s = weakSelf;
    if (!s) return;
    dispatch_async(s->_q, ^{
      if (s->_done) return;
      if (err) {
        [s finish];
        return;
      }
      if (data.length == 0) {
        shutdown(s->_fd, SHUT_WR);
        return;
      }
      if (sendAll(s->_fd, data.bytes, data.length) != 0) {
        [s finish];
        return;
      }
      [s readNext];
    });
  }];
}

- (void)finish {
  if (_done) return;
  _done = YES;
  if (_fd >= 0) {
    close(_fd);
    _fd = -1;
  }
  [_flow closeReadWithError:nil];
  [_flow closeWriteWithError:nil];
  if (_onDone) _onDone();
}

@end

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

@implementation AppProxyProvider {
  NSString* _proxyHost;
  uint16_t _proxyPort;
  NSMutableSet<Relay*>* _relays;
  dispatch_queue_t _relaysQ;
  BOOL _handlingUdp;
}

- (void)startProxyWithOptions:(NSDictionary<NSString*, id>*)options
            completionHandler:(void (^)(NSError* _Nullable))completionHandler {
  NETunnelProviderProtocol* appProto =
      (NETunnelProviderProtocol*)self.protocolConfiguration;
  NSDictionary* conf = appProto.providerConfiguration;
  _proxyHost = conf[@"proxyHost"] ?: @"127.0.0.1";
  _proxyPort = (uint16_t)([conf[@"proxyPort"] intValue] ?: 4447);
  _relays = [NSMutableSet new];
  _relaysQ = dispatch_queue_create("ios2pd.relays", DISPATCH_QUEUE_SERIAL);
  _handlingUdp = NO;

  NEPacketTunnelNetworkSettings* s =
      [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:@"10.192.0.1"];
  NEIPv4Settings* ipv4 =
      [[NEIPv4Settings alloc] initWithAddresses:@[ @"10.192.0.1" ]
                                   subnetMasks:@[ @"255.255.255.255" ]];
  NEIPv4Route* fake = [[NEIPv4Route alloc] initWithDestinationAddress:@"10.192.0.0"
                                                            subnetMask:@"255.192.0.0"];
  ipv4.includedRoutes = @[ fake ];
  s.IPv4Settings = ipv4;
  if (@available(iOS 14.0, *)) {
    NEDNSSettings* dns = [[NEDNSSettings alloc] initWithServers:@[ @"10.255.255.53" ]];
    dns.matchDomains = @[ @"i2p" ];
    s.DNSSettings = dns;
  }
  [self setTunnelNetworkSettings:s
               completionHandler:^(NSError* _Nullable error) {
                 completionHandler(error);
               }];
}

- (void)stopProxyWithReason:(NEProviderStopReason)reason
          completionHandler:(void (^)(void))completionHandler {
  completionHandler();
}

- (BOOL)handleNewFlow:(NEAppProxyFlow*)flow {
  NEAppProxyTCPFlow* tcp = (NEAppProxyTCPFlow*)flow;
  NSString* host = nil;
  uint16_t port = 0;
  nw_endpoint_t nep = NULL;
  if (@available(iOS 18.0, *)) {
    nep = tcp.remoteFlowEndpoint;
  }
  if (nep) {
    nw_endpoint_type_t et = nw_endpoint_get_type(nep);
    if (et == nw_endpoint_type_host) {
      const char* h = nw_endpoint_get_hostname(nep);
      if (h) host = [NSString stringWithUTF8String:h];
      port = nw_endpoint_get_port(nep);
    } else if (et == nw_endpoint_type_address) {
      char* a = nw_endpoint_copy_address_string(nep);
      if (a) {
        host = [NSString stringWithUTF8String:a];
        free(a);
      }
      port = nw_endpoint_get_port(nep);
    }
  }
  if (!host || port == 0) return NO;

  uint32_t ip = ipv4ToUint(host);
  BOOL fake = (ip >= FAKE_NET_BASE && ip < FAKE_NET_BASE + FAKE_NET_COUNT);
  NSString* target = host;
  BOOL direct = YES;
  if (fake) {
    NSString* name = nameForIp(ip);
    if (!name) {
      NSLog(@"[ios2pd] no reverse map for fake ip %@", host);
      return NO;
    }
    target = name;
    direct = NO;
  }

  Relay* r = [[Relay alloc] initWithFlow:tcp
                                    host:target
                                    port:port
                               socksHost:_proxyHost
                               socksPort:_proxyPort
                                  direct:direct];
  __weak typeof(self) weakSelf = self;
  __weak Relay* wr = r;
  r.onDone = ^{
    AppProxyProvider* s = weakSelf;
    if (!s) return;
    dispatch_async(s->_relaysQ, ^{
      [s->_relays removeObject:wr];
    });
  };
  dispatch_async(_relaysQ, ^{
    [self->_relays addObject:r];
    [r start];
  });
  return YES;
}

- (BOOL)handleNewUDPFlow:(NEAppProxyUDPFlow*)flow
   initialRemoteEndpoint:(NWEndpoint*)remoteEndpoint {
  // We only answer *.i2p DNS queries; everything else is dropped so the
  // clearnet UDP path is untouched.
  if (_handlingUdp) return NO;
  _handlingUdp = YES;
  [self pumpUdp:flow];
  return YES;
}

- (void)pumpUdp:(NEAppProxyUDPFlow*)flow {
  __weak typeof(self) weakSelf = self;
  [flow readDatagramsWithCompletionHandler:^(NSArray<NSData*>* datagrams,
                                            NSArray<NWEndpoint*>* remoteEndpoints,
                                            NSError* error) {
    AppProxyProvider* s = weakSelf;
    if (!s) return;
    if (error) {
      [flow closeReadWithError:nil];
      [flow closeWriteWithError:nil];
      return;
    }
    if (!datagrams.count) {
      [flow closeReadWithError:nil];
      [flow closeWriteWithError:nil];
      return;
    }
    NSMutableArray* replies = [NSMutableArray new];
    NSMutableArray* replyEnds = [NSMutableArray new];
    for (NSUInteger i = 0; i < datagrams.count; i++) {
      NSData* resp = buildDnsResponse(datagrams[i]);
      if (resp) {
        [replies addObject:resp];
        if (i < remoteEndpoints.count) {
          [replyEnds addObject:remoteEndpoints[i]];
        }
      }
    }
    if (replies.count && replies.count == replyEnds.count) {
      [flow writeDatagrams:replies
            sentByEndpoints:replyEnds
         completionHandler:^(NSError* e) {
           if (e) {
             [flow closeReadWithError:nil];
             [flow closeWriteWithError:nil];
           } else {
             [s pumpUdp:flow];
           }
         }];
    } else {
      [s pumpUdp:flow];
    }
  }];
}

@end

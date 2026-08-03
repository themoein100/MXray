//
//  XrayTunnelSettings.swift
//  MXray
//
//  Copyright 2026 Moein
//  SPDX-License-Identifier: Apache-2.0
//

#if canImport(NetworkExtension)
import NetworkExtension

/// The IP / DNS / MTU parameters MXray applies to the packet tunnel interface.
///
/// The defaults encode hard-won values for a full-tunnel Xray session on iOS. You rarely need to
/// change them, but every field is exposed so you can.
public struct XrayTunnelSettings: Sendable, Equatable {

    /// The tunnel's local IPv4 address on the utun interface.
    public var ipv4Address: String

    /// Subnet mask for ``ipv4Address``. A /30 is enough for a point-to-point tunnel.
    public var ipv4SubnetMask: String

    /// The (nominal) remote address reported to the system. `127.0.0.1` is correct — the real
    /// remote is reached by Xray, not by the OS routing table.
    public var tunnelRemoteAddress: String

    /// DNS resolvers advertised to the system inside the tunnel.
    public var dnsServers: [String]

    /// Domains the DNS settings match. `[""]` matches all domains (full-tunnel DNS).
    public var dnsMatchDomains: [String]

    /// Link MTU. Kept below common cellular / VLESS-over-TCP fragmentation thresholds while still
    /// high enough that large downloads don't pay a packet-count penalty. This value is also handed
    /// to Xray's gVisor `tun` inbound — the two MUST agree, or large packets silently vanish.
    public var mtu: Int

    /// When true, all traffic is routed into the tunnel (full tunnel). This is the only safe mode
    /// for a privacy VPN: any excluded route reaches the network from the device's real IP.
    public var routesAllTraffic: Bool

    public init(
        ipv4Address: String = "172.19.0.2",
        ipv4SubnetMask: String = "255.255.255.252",
        tunnelRemoteAddress: String = "127.0.0.1",
        dnsServers: [String] = ["1.1.1.1", "8.8.8.8"],
        dnsMatchDomains: [String] = [""],
        mtu: Int = 1400,
        routesAllTraffic: Bool = true
    ) {
        self.ipv4Address = ipv4Address
        self.ipv4SubnetMask = ipv4SubnetMask
        self.tunnelRemoteAddress = tunnelRemoteAddress
        self.dnsServers = dnsServers
        self.dnsMatchDomains = dnsMatchDomains
        self.mtu = mtu
        self.routesAllTraffic = routesAllTraffic
    }

    /// The default full-tunnel settings.
    public static let `default` = XrayTunnelSettings()

    /// Builds the `NEPacketTunnelNetworkSettings` these settings describe.
    public func makeNetworkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)

        let ipv4 = NEIPv4Settings(addresses: [ipv4Address], subnetMasks: [ipv4SubnetMask])
        ipv4.includedRoutes = routesAllTraffic ? [NEIPv4Route.default()] : []
        ipv4.excludedRoutes = []
        settings.ipv4Settings = ipv4
        settings.ipv6Settings = nil

        let dns = NEDNSSettings(servers: dnsServers)
        dns.matchDomains = dnsMatchDomains
        settings.dnsSettings = dns

        settings.mtu = NSNumber(value: mtu)
        return settings
    }
}
#endif

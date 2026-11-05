package client

import (
	"errors"
	"net"
	"net/netip"
	"os"

	"golang.org/x/sys/unix"
)

// overlayProbeSocket sends only through the interface holding this device's Nebula
// address, so a more specific LAN or VPN route cannot answer for a Nebula node.
func overlayProbeSocket(target, local netip.Addr) (net.PacketConn, error) {
	index, err := interfaceHolding(local)
	if err != nil {
		return nil, problem("probe_unavailable", "未找到 Nebula 隧道网卡，请断开后重新连接再测试。", "")
	}
	if target.Is6() != local.Is6() {
		return nil, problem("probe_unavailable", "未找到 Nebula 隧道网卡，请断开后重新连接再测试。", "")
	}
	family, protocol, level, option := unix.AF_INET, unix.IPPROTO_ICMP, unix.IPPROTO_IP, unix.IP_BOUND_IF
	var address unix.Sockaddr
	if target.Is6() {
		family, protocol, level, option = unix.AF_INET6, unix.IPPROTO_ICMPV6, unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF
		address = &unix.SockaddrInet6{Addr: local.As16()}
	} else {
		address = &unix.SockaddrInet4{Addr: local.As4()}
	}
	unavailable := problem("probe_unavailable", "系统未允许 ICMP 探测；仍可通过实际访问检查节点。", "")
	fd, err := unix.Socket(family, unix.SOCK_DGRAM, protocol)
	if err != nil {
		return nil, unavailable
	}
	unix.CloseOnExec(fd)
	// Replies on an IPv4 datagram socket otherwise carry the IP header (as in x/net/icmp).
	if family == unix.AF_INET && unix.SetsockoptInt(fd, unix.IPPROTO_IP, unix.IP_STRIPHDR, 1) != nil ||
		unix.SetsockoptInt(fd, level, option, index) != nil || unix.Bind(fd, address) != nil {
		unix.Close(fd)
		return nil, unavailable
	}
	file := os.NewFile(uintptr(fd), "nebula-probe")
	defer file.Close()
	conn, err := net.FilePacketConn(file)
	if err != nil {
		return nil, unavailable
	}
	return conn, nil
}

func interfaceHolding(local netip.Addr) (int, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return 0, err
	}
	for _, i := range interfaces {
		addresses, err := i.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addresses {
			if n, ok := a.(*net.IPNet); ok {
				if ip, ok := netip.AddrFromSlice(n.IP); ok && ip.Unmap() == local {
					return i.Index, nil
				}
			}
		}
	}
	return 0, errors.New("no interface holds the local Nebula address")
}

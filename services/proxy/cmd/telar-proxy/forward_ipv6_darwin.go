package main

import "golang.zx2c4.com/wireguard/tun"

type darwinIPv6Sender struct {
	device        tun.Device
	interfaceName string
	done          chan struct{}
}

// Darwin raw IPv6 sockets rebuild the IP header. A second TUN instead injects
// the complete packet; its private PF route-to rule sends it through the uplink.
func openIPv6Sender(interfaceName string) (ipv6Sender, error) {
	device, err := tun.CreateTUN("utun", tunnelMTU)
	if err != nil {
		return nil, err
	}

	name, err := device.Name()
	if err != nil {
		device.Close()
		return nil, err
	}

	sender := &darwinIPv6Sender{device: device, interfaceName: name, done: make(chan struct{})}
	go func() {
		defer close(sender.done)
		buffers := [][]byte{make([]byte, packetOffset+packetBufferSize)}
		sizes := make([]int, len(buffers))
		for {
			if _, err := device.Read(buffers, sizes, packetOffset); err != nil {
				return
			}
		}
	}()

	return sender, nil
}

func (self *darwinIPv6Sender) Send(frame []byte) error {
	return writeTunnelPacket(self.device, frame)
}

func (self *darwinIPv6Sender) Close() error {
	err := self.device.Close()
	<-self.done
	return err
}

func (self *darwinIPv6Sender) InterfaceName() string { return self.interfaceName }

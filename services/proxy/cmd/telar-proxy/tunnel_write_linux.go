package main

// This wireguard-go version reports bytes on Linux, including the virtio
// header when offloads are enabled. Older kernels can use the plain TUN path.
func tunnelWriteComplete(written int, frame []byte) bool {
	return written == len(frame) || written == len(frame)-packetOffset
}

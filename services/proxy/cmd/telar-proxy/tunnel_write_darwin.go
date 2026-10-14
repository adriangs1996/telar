package main

func tunnelWriteComplete(written int, frame []byte) bool {
	return written == 1
}

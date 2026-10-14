package main

import (
	"container/list"
	"errors"
	"net/netip"
	"time"
)

const (
	ipv6FragmentDecisionTimeout = 60 * time.Second
	ipv6MaxFragmentDecisions    = 1024
	ipv6MaxPendingBytes         = 4 * 1024 * 1024
	ipv6MaxPendingFragments     = 64
)

type ipv6FragmentKey struct {
	source      netip.Addr
	destination netip.Addr
	id          uint32
}

type ipv6FragmentDecision struct {
	key      ipv6FragmentKey
	next     byte
	protocol byte
	known    bool
	blocked  bool
	expires  time.Time
	pending  [][]byte
	bytes    int
}

// The TUN reader owns this dispatcher. It preserves original fragments and
// remembers only which handler to use; gVisor and the kernel still reassemble.
type ipv6FragmentDispatcher struct {
	decisions map[ipv6FragmentKey]*list.Element
	ordered   list.List
	bytes     int
}

func (self *ipv6FragmentDispatcher) dispatch(info packetProtocolInfo, frame []byte, forward func([]byte, byte) error) error {
	if !info.needsDecision {
		return forward(frame, info.protocol)
	}
	now := time.Now()
	self.expire(now)
	if self.decisions == nil {
		self.decisions = make(map[ipv6FragmentKey]*list.Element)
	}
	element := self.decisions[info.fragmentKey]
	if element == nil {
		if len(self.decisions) == ipv6MaxFragmentDecisions {
			self.remove(self.ordered.Front())
		}
		element = self.ordered.PushBack(&ipv6FragmentDecision{
			key:     info.fragmentKey,
			next:    info.fragmentNext,
			expires: now.Add(ipv6FragmentDecisionTimeout),
		})
		self.decisions[info.fragmentKey] = element
	}
	decision := element.Value.(*ipv6FragmentDecision)
	if decision.blocked {
		return errors.New("IPv6 fragment datagram was rejected")
	}
	if decision.next != info.fragmentNext || (info.known && decision.known && decision.protocol != info.protocol) {
		self.block(decision)
		return errors.New("conflicting IPv6 fragment protocols")
	}
	if info.known {
		decision.protocol = info.protocol
		decision.known = true
	}
	if decision.known {
		pending := decision.pending
		self.bytes -= decision.bytes
		decision.pending = nil
		decision.bytes = 0
		err := forward(frame, decision.protocol)
		for _, queued := range pending {
			err = errors.Join(err, forward(queued, decision.protocol))
		}
		return err
	}
	if len(decision.pending) == ipv6MaxPendingFragments || len(frame) > ipv6MaxPendingBytes-self.bytes {
		self.block(decision)
		return errors.New("IPv6 pending fragment limit reached")
	}
	decision.pending = append(decision.pending, append([]byte(nil), frame...))
	decision.bytes += len(frame)
	self.bytes += len(frame)
	return nil
}

func (self *ipv6FragmentDispatcher) block(decision *ipv6FragmentDecision) {
	self.bytes -= decision.bytes
	decision.pending = nil
	decision.bytes = 0
	decision.blocked = true
}

func (self *ipv6FragmentDispatcher) remove(element *list.Element) {
	decision := element.Value.(*ipv6FragmentDecision)
	self.bytes -= decision.bytes
	delete(self.decisions, decision.key)
	self.ordered.Remove(element)
}

func (self *ipv6FragmentDispatcher) expire(now time.Time) {
	for element := self.ordered.Front(); element != nil; element = self.ordered.Front() {
		if element.Value.(*ipv6FragmentDecision).expires.After(now) {
			return
		}
		self.remove(element)
	}
}

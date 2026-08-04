package nextv1

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/buf"
	xerrors "github.com/xtls/xray-core/common/errors"
	"github.com/xtls/xray-core/common/log"
	"github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/protocol"
	udpProtocol "github.com/xtls/xray-core/common/protocol/udp"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/common/signal"
	"github.com/xtls/xray-core/common/task"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/policy"
	"github.com/xtls/xray-core/features/routing"
	"github.com/xtls/xray-core/proxy"
	"github.com/xtls/xray-core/transport/internet/stat"
	"github.com/xtls/xray-core/transport/internet/udp"
)

const (
	defaultMaxTimeSkew = 120 * time.Second
	defaultReplaySize  = 65536
	defaultPaddingMax  = 64
)

func init() {
	common.Must(common.RegisterConfig((*Config)(nil), func(ctx context.Context, config interface{}) (interface{}, error) {
		return NewServer(ctx, config.(*Config))
	}))
}

type Server struct {
	policyManager policy.Manager
	users         *userStore
	maxTimeSkew   time.Duration
}

func NewServer(ctx context.Context, config *Config) (*Server, error) {
	maxTimeSkew := time.Duration(config.GetMaxTimeSkewSeconds()) * time.Second
	if maxTimeSkew == 0 {
		maxTimeSkew = defaultMaxTimeSkew
	}
	replayCapacity := int(config.GetReplayCapacity())
	if replayCapacity == 0 {
		replayCapacity = defaultReplaySize
	}
	instance := core.MustFromContext(ctx)
	return &Server{
		policyManager: instance.GetFeature(policy.ManagerType()).(policy.Manager),
		users:         newUserStore(replayCapacity, 2*maxTimeSkew),
		maxTimeSkew:   maxTimeSkew,
	}, nil
}

func (s *Server) AddUser(_ context.Context, user *protocol.MemoryUser) error {
	return s.users.Add(user)
}

func (s *Server) RemoveUser(_ context.Context, email string) error {
	return s.users.Remove(email)
}

func (s *Server) GetUser(_ context.Context, email string) *protocol.MemoryUser {
	return s.users.Get(email)
}

func (s *Server) GetUsers(context.Context) []*protocol.MemoryUser {
	return s.users.All()
}

func (s *Server) GetUsersCount(context.Context) int64 {
	return s.users.Count()
}

func (s *Server) Network() []net.Network {
	return []net.Network{net.Network_TCP, net.Network_UNIX}
}

func (s *Server) Process(ctx context.Context, network net.Network, conn stat.Connection, dispatcher routing.Dispatcher) error {
	if network != net.Network_TCP && network != net.Network_UNIX {
		return xerrors.New("Next-V1 only accepts stream transports")
	}
	if err := conn.SetReadDeadline(time.Now().Add(s.policyManager.ForLevel(0).Timeouts.Handshake)); err != nil {
		return xerrors.New("set Next-V1 handshake deadline").Base(err)
	}
	var rawHello [HelloSize]byte
	if _, err := io.ReadFull(conn, rawHello[:]); err != nil {
		return xerrors.New("read Next-V1 client hello").Base(err)
	}
	user, keys, command, err := s.users.Authenticate(rawHello, s.maxTimeSkew)
	if err != nil {
		return xerrors.New("reject Next-V1 client hello").Base(err)
	}
	recordReader, err := NewRecordReader(keys.c2s[:], true)
	if err != nil {
		return xerrors.New("create Next-V1 record reader").Base(err)
	}
	recordWriter, err := NewRecordWriter(keys.s2c[:], false, defaultPaddingMax)
	if err != nil {
		return xerrors.New("create Next-V1 record writer").Base(err)
	}
	open, err := recordReader.ReadRecord(conn)
	if err != nil {
		return xerrors.New("read Next-V1 OPEN").Base(err)
	}
	if open.Type != RecordOpen {
		_ = writeProtocolError(conn, recordWriter, "first record must be OPEN")
		return xerrors.New("Next-V1 first record is not OPEN")
	}
	targetNetwork := net.Network_TCP
	if command == CommandUDP {
		targetNetwork = net.Network_UDP
	}
	destination, err := ParseDestination(open.Payload, targetNetwork)
	if err != nil {
		_ = writeProtocolError(conn, recordWriter, "invalid destination")
		return xerrors.New("parse Next-V1 destination").Base(err)
	}
	if err := conn.SetReadDeadline(time.Time{}); err != nil {
		return xerrors.New("clear Next-V1 handshake deadline").Base(err)
	}
	inbound := session.InboundFromContext(ctx)
	if inbound == nil {
		inbound = &session.Inbound{}
		ctx = session.ContextWithInbound(ctx, inbound)
	}
	inbound.Name = "Next-V1"
	inbound.CanSpliceCopy = 3
	inbound.User = user
	ctx = log.ContextWithAccessMessage(ctx, &log.AccessMessage{
		From:   conn.RemoteAddr(),
		To:     destination,
		Status: log.AccessAccepted,
		Email:  user.Email,
	})
	xerrors.LogInfo(ctx, "received Next-V1 request for ", destination)
	sessionPolicy := s.policyManager.ForLevel(user.Level)
	ctx = policy.ContextWithBufferPolicy(ctx, sessionPolicy.Buffer)
	if command == CommandUDP {
		return s.handleUDP(ctx, sessionPolicy, destination, conn, recordReader, recordWriter, dispatcher)
	}
	return s.handleTCP(ctx, sessionPolicy, destination, conn, recordReader, recordWriter, dispatcher)
}

func (s *Server) handleTCP(ctx context.Context, sessionPolicy policy.Session, destination net.Destination, conn stat.Connection, reader *RecordReader, writer *RecordWriter, dispatcher routing.Dispatcher) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	timer := signal.CancelAfterInactivity(ctx, cancel, sessionPolicy.Timeouts.ConnectionIdle)
	defer timer.SetTimeout(0)
	link, err := dispatcher.Dispatch(ctx, destination)
	if err != nil {
		_ = writeProtocolError(conn, writer, "dispatch failed")
		return xerrors.New("dispatch Next-V1 TCP request to ", destination).Base(err)
	}
	if err := writer.WriteRecord(conn, RecordAck, nil); err != nil {
		common.Interrupt(link.Reader)
		common.Interrupt(link.Writer)
		return xerrors.New("write Next-V1 ACK").Base(err)
	}

	requestDone := func() error {
		defer timer.SetTimeout(sessionPolicy.Timeouts.DownlinkOnly)
		for {
			record, err := reader.ReadRecord(conn)
			if err != nil {
				if errors.Is(err, io.EOF) {
					return nil
				}
				return xerrors.New("read Next-V1 TCP data").Base(err)
			}
			timer.Update()
			switch record.Type {
			case RecordData:
				if len(record.Payload) == 0 {
					continue
				}
				if err := link.Writer.WriteMultiBuffer(buf.MultiBuffer{buf.FromBytes(record.Payload)}); err != nil {
					return xerrors.New("forward Next-V1 TCP data").Base(err)
				}
			case RecordClose:
				return nil
			default:
				return fmt.Errorf("unexpected Next-V1 record 0x%02x after OPEN", record.Type)
			}
		}
	}

	responseDone := func() error {
		defer timer.SetTimeout(sessionPolicy.Timeouts.UplinkOnly)
		for {
			multiBuffer, err := link.Reader.ReadMultiBuffer()
			if err != nil {
				if errors.Is(err, io.EOF) {
					return writer.WriteRecord(conn, RecordClose, nil)
				}
				return xerrors.New("read Next-V1 TCP response").Base(err)
			}
			timer.Update()
			if err := writeTCPResponse(conn, writer, multiBuffer); err != nil {
				return xerrors.New("write Next-V1 TCP response").Base(err)
			}
		}
	}

	requestDonePost := task.OnSuccess(requestDone, task.Close(link.Writer))
	if err := task.Run(ctx, requestDonePost, responseDone); err != nil {
		common.Interrupt(link.Reader)
		common.Interrupt(link.Writer)
		return xerrors.New("Next-V1 TCP connection ended").Base(err)
	}
	return nil
}

func writeTCPResponse(conn io.Writer, writer *RecordWriter, multiBuffer buf.MultiBuffer) error {
	defer buf.ReleaseMulti(multiBuffer)
	for _, buffer := range multiBuffer {
		data := buffer.Bytes()
		for len(data) > 0 {
			length := len(data)
			if length > MaxDataSize {
				length = MaxDataSize
			}
			if err := writer.WriteRecord(conn, RecordData, data[:length]); err != nil {
				return err
			}
			data = data[length:]
		}
	}
	return nil
}

func (s *Server) handleUDP(ctx context.Context, sessionPolicy policy.Session, destination net.Destination, conn stat.Connection, reader *RecordReader, writer *RecordWriter, dispatcher routing.Dispatcher) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	timer := signal.CancelAfterInactivity(ctx, cancel, sessionPolicy.Timeouts.ConnectionIdle)
	defer timer.SetTimeout(0)
	writeErrors := make(chan error, 1)
	udpDispatcher := udp.NewDispatcher(dispatcher, func(_ context.Context, packet *udpProtocol.Packet) {
		defer packet.Payload.Release()
		if err := writer.WriteRecord(conn, RecordData, packet.Payload.Bytes()); err != nil {
			select {
			case writeErrors <- err:
			default:
			}
			cancel()
			return
		}
		timer.Update()
	})
	defer udpDispatcher.RemoveRay()
	if err := writer.WriteRecord(conn, RecordAck, nil); err != nil {
		return xerrors.New("write Next-V1 UDP ACK").Base(err)
	}

	requestDone := func() error {
		for {
			record, err := reader.ReadRecord(conn)
			if err != nil {
				if errors.Is(err, io.EOF) {
					return nil
				}
				return xerrors.New("read Next-V1 UDP datagram").Base(err)
			}
			timer.Update()
			switch record.Type {
			case RecordData:
				payload := buf.FromBytes(record.Payload)
				payload.UDP = &destination
				udpDispatcher.Dispatch(ctx, destination, payload)
			case RecordClose:
				return nil
			default:
				return fmt.Errorf("unexpected Next-V1 record 0x%02x after OPEN", record.Type)
			}
		}
	}

	if err := task.Run(ctx, requestDone); err != nil {
		select {
		case writeErr := <-writeErrors:
			return xerrors.New("write Next-V1 UDP response").Base(writeErr)
		default:
			return xerrors.New("Next-V1 UDP connection ended").Base(err)
		}
	}
	return nil
}

func writeProtocolError(conn io.Writer, writer *RecordWriter, message string) error {
	if len(message) > MaxReasonSize {
		message = message[:MaxReasonSize]
	}
	return writer.WriteRecord(conn, RecordError, []byte(message))
}

var (
	_ proxy.Inbound     = (*Server)(nil)
	_ proxy.UserManager = (*Server)(nil)
)

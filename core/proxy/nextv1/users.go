package nextv1

import (
	"errors"
	"sync"
	"time"

	"github.com/xtls/xray-core/common/protocol"
)

type userEntry struct {
	password string
	user     *protocol.MemoryUser
}

type replayKey struct {
	userHash [16]byte
	nonce    [16]byte
}

type replayEntry struct {
	key       replayKey
	expiresAt time.Time
}

type userStore struct {
	mu        sync.RWMutex
	byHash    map[[16]byte]userEntry
	byEmail   map[string]*protocol.MemoryUser
	replayMu  sync.Mutex
	replays   map[replayKey]time.Time
	queue     []replayEntry
	capacity  int
	retention time.Duration
	now       func() time.Time
}

func newUserStore(capacity int, retention time.Duration) *userStore {
	if capacity <= 0 {
		capacity = 65536
	}
	return &userStore{
		byHash:    make(map[[16]byte]userEntry),
		byEmail:   make(map[string]*protocol.MemoryUser),
		replays:   make(map[replayKey]time.Time),
		capacity:  capacity,
		retention: retention,
		now:       time.Now,
	}
}

func (s *userStore) Add(user *protocol.MemoryUser) error {
	account, ok := user.Account.(*MemoryAccount)
	if !ok {
		return errors.New("Next-V1 user has an incompatible account")
	}
	password := normalizePassword(account.Password)
	if password == "" {
		return errors.New("Next-V1 password is empty")
	}
	hash := deriveUserHash(password)
	s.mu.Lock()
	defer s.mu.Unlock()
	if existing, ok := s.byHash[hash]; ok && existing.user.Email != user.Email {
		return errors.New("Next-V1 user hash collision")
	}
	if existing, ok := s.byEmail[user.Email]; ok {
		delete(s.byHash, deriveUserHash(existing.Account.(*MemoryAccount).Password))
	}
	s.byHash[hash] = userEntry{password: password, user: user}
	s.byEmail[user.Email] = user
	return nil
}

func (s *userStore) Remove(email string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	user, ok := s.byEmail[email]
	if !ok {
		return errors.New("Next-V1 user not found")
	}
	account := user.Account.(*MemoryAccount)
	delete(s.byHash, deriveUserHash(account.Password))
	delete(s.byEmail, email)
	return nil
}

func (s *userStore) Get(email string) *protocol.MemoryUser {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.byEmail[email]
}

func (s *userStore) All() []*protocol.MemoryUser {
	s.mu.RLock()
	defer s.mu.RUnlock()
	users := make([]*protocol.MemoryUser, 0, len(s.byEmail))
	for _, user := range s.byEmail {
		users = append(users, user)
	}
	return users
}

func (s *userStore) Count() int64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return int64(len(s.byEmail))
}

func (s *userStore) Authenticate(raw [HelloSize]byte, maxSkew time.Duration) (*protocol.MemoryUser, sessionKeys, byte, error) {
	hello, err := parseClientHello(raw)
	if err != nil {
		return nil, sessionKeys{}, 0, err
	}
	now := s.now()
	difference := now.Sub(hello.time)
	if difference < 0 {
		difference = -difference
	}
	if difference > maxSkew {
		return nil, sessionKeys{}, 0, errors.New("Next-V1 client timestamp is outside the allowed window")
	}
	s.mu.RLock()
	entry, ok := s.byHash[hello.userHash]
	s.mu.RUnlock()
	if !ok || !verifyClientHello(hello, entry.password) {
		return nil, sessionKeys{}, 0, errors.New("Next-V1 authentication failed")
	}
	if !s.reserveReplay(hello.userHash, hello.nonce, now) {
		return nil, sessionKeys{}, 0, errors.New("Next-V1 replay detected")
	}
	keys, err := deriveSessionKeys(entry.password, hello.nonce)
	if err != nil {
		return nil, sessionKeys{}, 0, err
	}
	return entry.user, keys, hello.command, nil
}

func (s *userStore) reserveReplay(userHash [16]byte, nonce [16]byte, now time.Time) bool {
	s.replayMu.Lock()
	defer s.replayMu.Unlock()
	for len(s.queue) > 0 && !s.queue[0].expiresAt.After(now) {
		entry := s.queue[0]
		s.queue = s.queue[1:]
		if expiresAt, ok := s.replays[entry.key]; ok && expiresAt.Equal(entry.expiresAt) {
			delete(s.replays, entry.key)
		}
	}
	key := replayKey{userHash: userHash, nonce: nonce}
	if expiresAt, ok := s.replays[key]; ok && expiresAt.After(now) {
		return false
	}
	for len(s.replays) >= s.capacity && len(s.queue) > 0 {
		entry := s.queue[0]
		s.queue = s.queue[1:]
		if expiresAt, ok := s.replays[entry.key]; ok && expiresAt.Equal(entry.expiresAt) {
			delete(s.replays, entry.key)
		}
	}
	expiresAt := now.Add(s.retention)
	s.replays[key] = expiresAt
	s.queue = append(s.queue, replayEntry{key: key, expiresAt: expiresAt})
	return true
}

package nextv1

import (
	"context"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/protocol"
)

func TestUserStoreAuthenticationReplayAndSkew(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	store := newUserStore(2, 240*time.Second)
	store.now = func() time.Time { return now }
	user := &protocol.MemoryUser{
		Email:   "node:user@example",
		Account: &MemoryAccount{Password: " user-secret "},
	}
	if err := store.Add(user); err != nil {
		t.Fatal(err)
	}
	var nonce [16]byte
	copy(nonce[:], "replay-test-one!")
	raw, err := buildClientHello(CommandUDP, "user-secret", now, nonce)
	if err != nil {
		t.Fatal(err)
	}
	authenticated, _, command, err := store.Authenticate(raw, 120*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if authenticated != user || command != CommandUDP {
		t.Fatal("wrong authenticated user or command")
	}
	if _, _, _, err := store.Authenticate(raw, 120*time.Second); err == nil {
		t.Fatal("replayed hello was accepted")
	}

	copy(nonce[:], "replay-test-two!")
	stale, _ := buildClientHello(CommandTCP, "user-secret", now.Add(-121*time.Second), nonce)
	if _, _, _, err := store.Authenticate(stale, 120*time.Second); err == nil {
		t.Fatal("stale hello was accepted")
	}
	wrongPassword, _ := buildClientHello(CommandTCP, "not-the-user", now, nonce)
	if _, _, _, err := store.Authenticate(wrongPassword, 120*time.Second); err == nil {
		t.Fatal("unknown user was accepted")
	}
}

func TestUserStoreDynamicManagement(t *testing.T) {
	store := newUserStore(8, time.Minute)
	user := &protocol.MemoryUser{Email: "dynamic@example", Account: &MemoryAccount{Password: "dynamic-secret"}}
	if err := store.Add(user); err != nil {
		t.Fatal(err)
	}
	if got := store.Get(user.Email); got != user || store.Count() != 1 || len(store.All()) != 1 {
		t.Fatal("dynamic user was not stored")
	}
	if err := store.Remove(user.Email); err != nil {
		t.Fatal(err)
	}
	if store.Get(user.Email) != nil || store.Count() != 0 {
		t.Fatal("dynamic user was not removed")
	}
	if err := store.Remove(user.Email); err == nil {
		t.Fatal("removing an unknown user should fail")
	}
}

func TestAccountConversion(t *testing.T) {
	protoUser := &protocol.User{Email: "account@example"}
	account, err := (&Account{Password: "  password  "}).AsAccount()
	if err != nil {
		t.Fatal(err)
	}
	protoUser.Account = nil
	memory := &protocol.MemoryUser{Email: protoUser.Email, Account: account}
	server := &Server{users: newUserStore(8, time.Minute)}
	if err := server.AddUser(context.Background(), memory); err != nil {
		t.Fatal(err)
	}
	if server.GetUsersCount(context.Background()) != 1 {
		t.Fatal("Server UserManager did not add the account")
	}
}

package nextv1

import (
	"errors"

	"github.com/xtls/xray-core/common/protocol"
	"google.golang.org/protobuf/proto"
)

type MemoryAccount struct {
	Password string
}

func (a *Account) AsAccount() (protocol.Account, error) {
	password := normalizePassword(a.GetPassword())
	if password == "" {
		return nil, errors.New("Next-V1 password is empty")
	}
	return &MemoryAccount{Password: password}, nil
}

func (a *MemoryAccount) Equals(other protocol.Account) bool {
	account, ok := other.(*MemoryAccount)
	return ok && a.Password == account.Password
}

func (a *MemoryAccount) ToProto() proto.Message {
	return &Account{Password: a.Password}
}

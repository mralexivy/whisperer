package gcp_test

import (
	"testing"

	"github.com/mralexivy/whisperer/server/internal/account"
	"github.com/mralexivy/whisperer/server/internal/account/accounttest"
	"github.com/mralexivy/whisperer/server/internal/gcp"
)

func TestAccountStoreOnFirestore(t *testing.T) {
	accounttest.Contract(t, func(t *testing.T) account.Store {
		fs, _ := newFS(t)
		return gcp.AccountStore{FS: fs}
	})
}

func TestAccountStoreInMemory(t *testing.T) {
	accounttest.Contract(t, func(t *testing.T) account.Store { return account.NewMemory() })
}

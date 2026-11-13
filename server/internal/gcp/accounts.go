package gcp

import (
	"context"
	"errors"

	"github.com/mralexivy/whisperer/server/internal/account"
)

// AccountStore keeps accounts in Firestore. It implements account.Store.
//
// Layout under the root: accounts/{accountId}, subscriptions/{subKey} and tokens/{appAccountToken} (each
// {accountId}), and devices/{deviceId} with an accountId field. Devices are a flat collection rather than
// the plan's accounts/{id}/devices so that "which account owns this device key" is one document get on a
// globally unique name — the same document is the uniqueness guarantee. Pending devices carry `purgeAt`,
// the field a Firestore TTL policy on `devices` deletes by.
type AccountStore struct{ FS *Firestore }

type mapping struct {
	AccountID string `json:"accountId"`
}

func acctPath(id string) string { return "accounts/" + id }
func subPath(k string) string   { return "subscriptions/" + k }
func tokPath(t string) string   { return "tokens/" + t }
func devPath(id string) string  { return "devices/" + id }

func (s AccountStore) Create(ctx context.Context, c account.Creation) error {
	a := c.Account
	a.Normalize()
	c.Device.AccountID = a.ID
	writes := []Write{
		{Path: subPath(c.SubKey), Doc: mapping{a.ID}, MustNotExist: true},
		{Path: devPath(c.Device.ID), Doc: c.Device, MustNotExist: true},
		{Path: acctPath(a.ID), Doc: a, MustNotExist: true},
	}
	if a.AppAccountToken != "" {
		writes = append(writes, Write{Path: tokPath(a.AppAccountToken), Doc: mapping{a.ID}, MustNotExist: true})
	}
	err := s.FS.Commit(ctx, writes)
	if errors.Is(err, ErrExists) {
		// The commit wrote nothing. Say which name was taken: the device key is the case the caller handles differently.
		if _, ok, derr := s.GetDevice(ctx, c.Device.ID); derr == nil && ok {
			return account.ErrDeviceBound
		}
		return account.ErrBound
	}
	return err
}

func (s AccountStore) resolve(ctx context.Context, path string) (string, bool, error) {
	var m mapping
	err := s.FS.Get(ctx, path, &m)
	if errors.Is(err, ErrNotFound) {
		return "", false, nil
	}
	return m.AccountID, err == nil && m.AccountID != "", err
}

func (s AccountStore) ResolveSub(ctx context.Context, subKey string) (string, bool, error) {
	return s.resolve(ctx, subPath(subKey))
}

func (s AccountStore) ResolveToken(ctx context.Context, t string) (string, bool, error) {
	return s.resolve(ctx, tokPath(t))
}

func (s AccountStore) BindSub(ctx context.Context, accountID, subKey string) error {
	err := s.FS.Commit(ctx, []Write{{Path: subPath(subKey), Doc: mapping{accountID}, MustNotExist: true}})
	if errors.Is(err, ErrExists) {
		id, ok, rerr := s.ResolveSub(ctx, subKey)
		if rerr != nil {
			return rerr
		}
		if ok && id == accountID {
			return nil
		}
		return account.ErrBound
	}
	return err
}

func (s AccountStore) GetAccount(ctx context.Context, id string) (account.Account, bool, error) {
	var a account.Account
	err := s.FS.Get(ctx, acctPath(id), &a)
	if errors.Is(err, ErrNotFound) {
		return a, false, nil
	}
	return a, err == nil, err
}

func (s AccountStore) UpdateAccount(ctx context.Context, id string, fn func(*account.Account) error) error {
	var a account.Account
	return s.FS.Transact(ctx, acctPath(id), &a, func() error {
		if a.ID == "" {
			return account.ErrNotFound
		}
		if err := fn(&a); err != nil {
			return err
		}
		a.ID = id
		a.Normalize()
		return nil
	})
}

func (s AccountStore) PendingEpochs(ctx context.Context, limit int) ([]account.Account, error) {
	var out []account.Account
	err := s.FS.Query(ctx, "accounts", []Filter{{"epochQueue", "EQUAL", "pending"}}, "", limit, func(m map[string]any) error {
		var a account.Account
		if err := FromMap(m, &a); err != nil {
			return err
		}
		out = append(out, a)
		return nil
	})
	return out, err
}

func (s AccountStore) GetDevice(ctx context.Context, id string) (account.Device, bool, error) {
	var d account.Device
	err := s.FS.Get(ctx, devPath(id), &d)
	if errors.Is(err, ErrNotFound) {
		return d, false, nil
	}
	return d, err == nil, err
}

func (s AccountStore) ListDevices(ctx context.Context, accountID string) ([]account.Device, error) {
	var out []account.Device
	err := s.FS.Query(ctx, "devices", []Filter{{"accountId", "EQUAL", accountID}}, "", 100, func(m map[string]any) error {
		var d account.Device
		if err := FromMap(m, &d); err != nil {
			return err
		}
		out = append(out, d)
		return nil
	})
	sortDevices(out)
	return out, err
}

func sortDevices(d []account.Device) {
	for i := 1; i < len(d); i++ {
		for j := i; j > 0 && (d[j].EnrolledAt.Before(d[j-1].EnrolledAt) || (d[j].EnrolledAt.Equal(d[j-1].EnrolledAt) && d[j].ID < d[j-1].ID)); j-- {
			d[j], d[j-1] = d[j-1], d[j]
		}
	}
}

func (s AccountStore) PutDevice(ctx context.Context, d account.Device) error {
	old, ok, err := s.GetDevice(ctx, d.ID)
	if err != nil {
		return err
	}
	if ok {
		if old.AccountID != d.AccountID {
			return account.ErrDeviceBound
		}
		return s.FS.Set(ctx, devPath(d.ID), d)
	}
	err = s.FS.Commit(ctx, []Write{{Path: devPath(d.ID), Doc: d, MustNotExist: true}})
	if errors.Is(err, ErrExists) {
		return account.ErrDeviceBound // lost a race to claim the key
	}
	return err
}

func (s AccountStore) UpdateDevice(ctx context.Context, id string, fn func(*account.Device) error) error {
	var d account.Device
	return s.FS.Transact(ctx, devPath(id), &d, func() error {
		if d.ID == "" {
			return account.ErrNotFound
		}
		if err := fn(&d); err != nil {
			return err
		}
		d.ID = id
		return nil
	})
}

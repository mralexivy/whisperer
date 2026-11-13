package server

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/mralexivy/whisperer/server/internal/auth"
	"github.com/mralexivy/whisperer/server/internal/entitlement"
	"github.com/mralexivy/whisperer/server/internal/quota"
	"github.com/mralexivy/whisperer/server/internal/retention"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

// WithSync turns on the storage routes (/v1/sync/*).
func (s *Server) WithSync(svc *syncplane.Service) *Server { s.sync = svc; return s }

// WithSweeper turns on the retention sweep. There is no scheduler: the sweep rides on requests the server is
// already handling (Apple's notifications and a fraction of sessions), which is plenty because deletion
// happens weeks after a subscription ends and a day's delay costs cents.
func (s *Server) WithSweeper(sw *retention.Sweeper) *Server { s.sweeper = sw; return s }

func (s *Server) syncRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/sync/heads", s.limited(s.authed(s.handleHeads)))
	mux.HandleFunc("POST /v1/sync/upload", s.limited(s.authed(s.handleUpload)))
	mux.HandleFunc("POST /v1/sync/commit", s.limited(s.authed(s.handleCommit)))
	mux.HandleFunc("POST /v1/sync/download", s.limited(s.authed(s.handleDownload)))
	mux.HandleFunc("POST /v1/sync/delete", s.limited(s.authed(s.handleDelete)))
}

// library resolves who is calling from the entitlement as it is now, not from the token: a refund or a
// lapse takes effect on the very next write, whatever the token still says.
func (s *Server) library(ctx context.Context, c auth.Claims) (lib syncplane.Library, state entitlement.State, err error) {
	e, found, err := s.store.Get(ctx, c.UID)
	if err != nil {
		return lib, "", err
	}
	if !found {
		return lib, "", errNoAccount
	}
	now := s.cfg.Now()
	pl, _ := s.planFor(e.ProductID)
	heads, err := s.sync.Store.GetHeads(ctx, c.UID)
	if err != nil {
		return lib, "", err
	}
	return syncplane.Library{Account: c.UID, Epoch: heads.Epoch, Limits: pl.Limits}, e.StateAt(now), nil
}

var errNoAccount = errors.New("no account")

func (s *Server) syncReady(w http.ResponseWriter) bool {
	if s.sync == nil {
		fail(w, 503, "sync_unavailable", "cloud sync is not enabled on this server")
		return false
	}
	return true
}

// syncFail maps a sync error to an HTTP answer. Quota errors are the user's to fix; the rest are ours.
func (s *Server) syncFail(w http.ResponseWriter, what string, err error) {
	switch {
	case errors.Is(err, errNoAccount):
		fail(w, 404, "no_account", "no subscription found")
	case errors.Is(err, syncplane.ErrReadOnly):
		fail(w, 403, "read_only", "this subscription is not active; your data is read-only")
	case errors.Is(err, quota.ErrOverQuota):
		fail(w, 402, "over_quota", "your stored data exceeds this plan; free some space or upgrade")
	case errors.Is(err, quota.ErrStorageFull):
		fail(w, 402, "storage_full", "this plan's storage is full")
	case errors.Is(err, quota.ErrDownloadLimit):
		fail(w, 429, "download_limit", "the monthly download allowance is used")
	case errors.Is(err, quota.ErrGrantLimit):
		fail(w, 429, "too_many_uploads", "too many uploads; try again later")
	case errors.Is(err, syncplane.ErrBadRequest), errors.Is(err, syncplane.ErrTooManyNames), errors.Is(err, syncplane.ErrBadName):
		fail(w, 400, "bad_request", "the request names objects that are not valid")
	case errors.Is(err, syncplane.ErrNotUploaded):
		fail(w, 409, "not_uploaded", "the object has not been uploaded")
	case errors.Is(err, syncplane.ErrCRCMismatch):
		fail(w, 409, "checksum_mismatch", "the uploaded object does not match")
	case errors.Is(err, syncplane.ErrNotFound):
		fail(w, 404, "not_found", "no such object")
	default:
		s.fault(w, what, err)
	}
}

func (s *Server) handleHeads(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	if !s.syncReady(w) {
		return
	}
	var since int64
	if v := r.URL.Query().Get("since"); v != "" {
		for _, ch := range v {
			if ch < '0' || ch > '9' || since > 1<<50 {
				fail(w, 400, "bad_request", "since must be a version number")
				return
			}
			since = since*10 + int64(ch-'0')
		}
	}
	h, unchanged, err := s.sync.HeadsSince(r.Context(), syncplane.Library{Account: c.UID}, since)
	if err != nil {
		s.syncFail(w, "heads", err)
		return
	}
	resp := map[string]any{"serverTime": s.cfg.Now().UTC(), "readOnly": c.ReadOnly}
	if unchanged {
		resp["unchanged"], resp["version"] = true, h.Version
	} else {
		resp["version"], resp["epoch"], resp["heads"], resp["snapshot"] = h.Version, h.Epoch, h.Heads, h.Snapshot
	}
	writeJSON(w, 200, resp)
}

func (s *Server) handleUpload(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	if !s.syncReady(w) {
		return
	}
	var req struct {
		Objects []syncplane.GrantRequest `json:"objects"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	lib, state, err := s.library(r.Context(), c)
	if err != nil {
		s.syncFail(w, "library", err)
		return
	}
	grants, err := s.sync.Grant(r.Context(), lib, state != entitlement.Active && state != entitlement.Grace, req.Objects)
	if err != nil {
		s.syncFail(w, "grant", err)
		return
	}
	writeJSON(w, 200, map[string]any{"grants": grants})
}

func (s *Server) handleCommit(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	if !s.syncReady(w) {
		return
	}
	var req syncplane.CommitRequest
	if !readJSON(w, r, &req) {
		return
	}
	lib, state, err := s.library(r.Context(), c)
	if err != nil {
		s.syncFail(w, "library", err)
		return
	}
	res, err := s.sync.Commit(r.Context(), lib, state != entitlement.Active && state != entitlement.Grace, req)
	if errors.Is(err, syncplane.ErrSeqConflict) {
		// The caller's counter is behind or ahead: tell it the head so it can resync.
		writeJSON(w, 409, map[string]any{"error": "sequence_conflict", "message": "resync your sequence number", "head": res.Head})
		return
	}
	if err != nil {
		s.syncFail(w, "commit", err)
		return
	}
	writeJSON(w, 200, res)
}

func (s *Server) handleDownload(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	if !s.syncReady(w) {
		return
	}
	var req struct {
		Objects []syncplane.Ref `json:"objects"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	lib, state, err := s.library(r.Context(), c)
	if err != nil {
		s.syncFail(w, "library", err)
		return
	}
	if !readable(state) {
		fail(w, 403, "no_access", "this subscription's data is no longer available")
		return
	}
	if state == entitlement.Sealed {
		for _, ref := range req.Objects {
			if ref.Kind == syncplane.KindAudio || ref.Kind == syncplane.KindMeeting {
				fail(w, 403, "sealed", "your plan lapsed; only text can be exported now — resubscribe to restore audio")
				return
			}
		}
	}
	grants, err := s.sync.Download(r.Context(), lib, req.Objects)
	if err != nil {
		s.syncFail(w, "download", err)
		return
	}
	writeJSON(w, 200, map[string]any{"grants": grants})
}

func readable(state entitlement.State) bool {
	switch state {
	case entitlement.Active, entitlement.Grace, entitlement.Lapsed, entitlement.Sealed:
		return true
	}
	return false
}

func (s *Server) handleDelete(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	if !s.syncReady(w) {
		return
	}
	var req struct {
		Objects []syncplane.Ref `json:"objects"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	lib, state, err := s.library(r.Context(), c)
	if err != nil {
		s.syncFail(w, "library", err)
		return
	}
	if !readable(state) {
		fail(w, 403, "no_access", "this subscription's data is no longer available")
		return
	}
	n, err := s.sync.Delete(r.Context(), lib, req.Objects)
	if err != nil {
		s.syncFail(w, "delete", err)
		return
	}
	writeJSON(w, 200, map[string]int{"deleted": n})
}

// sweepNow runs one bounded, guarded retention pass inside the current request. It is synchronous on purpose:
// Cloud Run throttles CPU once a response is sent, so a background goroutine would be starved.
func (s *Server) sweepNow(ctx context.Context) {
	if s.sweeper == nil {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	s.sweeper.Run(ctx)
}

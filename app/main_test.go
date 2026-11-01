package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type testSessionStore struct {
	pingErr     error
	refreshErr  error
	sessions    map[string]Session
	visitors    map[string]time.Time
	now         time.Time
	nextSession int
}

func newTestSessionStore(now time.Time) *testSessionStore {
	return &testSessionStore{
		sessions: map[string]Session{},
		visitors: map[string]time.Time{},
		now:      now,
	}
}

func (store *testSessionStore) Check(context.Context) error { return store.pingErr }

func (store *testSessionStore) Refresh(_ context.Context, browserID, hostname string) (Session, error) {
	if store.refreshErr != nil {
		return Session{}, store.refreshErr
	}
	session, ok := store.sessions[browserID]
	if !ok || store.now.Sub(session.StartedAt) > sessionTTL {
		store.nextSession++
		session = Session{BrowserID: browserID, ID: fmt.Sprintf("session-%d", store.nextSession), StartedAt: store.now}
	}
	session.PageLoads++
	session.ServingHostname = hostname
	store.visitors[browserID] = store.now
	for id, seenAt := range store.visitors {
		if store.now.Sub(seenAt) > sessionTTL {
			delete(store.visitors, id)
		}
	}
	session.ActiveVisitors = int64(len(store.visitors))
	session.ExpiresAt = store.now.Add(sessionTTL)
	session.ExpiresIn = formatCountdown(int64(sessionTTL / time.Second))
	store.sessions[browserID] = session
	return session, nil
}

func newTestServer(t *testing.T, store SessionStore) Server {
	t.Helper()
	files, err := fs.Sub(website, "static")
	if err != nil {
		t.Fatal(err)
	}
	status := &Status{State: "ok", startedAt: time.Now()}
	status.ready.Store(true)
	return Server{
		data: TemplateData{
			Environment: Environment{Hostname: "test-host"},
			Status:      status,
			User:        UserData{},
		},
		files:    files,
		sessions: store,
	}
}

func TestSessionStoreCreatesRefreshesAndExpiresSessions(t *testing.T) {
	now := time.Date(2026, time.November, 1, 0, 0, 0, 0, time.UTC)
	store := newTestSessionStore(now)

	first, err := store.Refresh(context.Background(), "browser-a", "app-a")
	if err != nil {
		t.Fatal(err)
	}
	store.now = store.now.Add(10 * time.Second)
	second, err := store.Refresh(context.Background(), "browser-a", "app-b")
	if err != nil {
		t.Fatal(err)
	}
	if second.ID != first.ID || second.PageLoads != 2 || second.ServingHostname != "app-b" {
		t.Fatalf("refresh = %#v, want retained ID, two page loads, and latest host", second)
	}

	_, err = store.Refresh(context.Background(), "browser-b", "app-a")
	if err != nil {
		t.Fatal(err)
	}
	if got := store.sessions["browser-b"].ActiveVisitors; got != 2 {
		t.Fatalf("active visitors = %d, want 2", got)
	}

	store.now = now.Add(sessionTTL + 20*time.Second)
	replacement, err := store.Refresh(context.Background(), "browser-a", "app-a")
	if err != nil {
		t.Fatal(err)
	}
	if replacement.ID == first.ID || replacement.PageLoads != 1 || replacement.ActiveVisitors != 1 {
		t.Fatalf("expired refresh = %#v, want new one-load session and one active visitor", replacement)
	}
}

func TestHTMLUsesAndReusesBrowserCookie(t *testing.T) {
	store := newTestSessionStore(time.Now())
	server := newTestServer(t, store)

	first := httptest.NewRequest(http.MethodGet, "/", nil)
	firstResponse := httptest.NewRecorder()
	server.route().ServeHTTP(firstResponse, first)
	if firstResponse.Code != http.StatusOK {
		t.Fatalf("first status = %d", firstResponse.Code)
	}
	cookies := firstResponse.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Name != browserCookieName || !cookies[0].HttpOnly {
		t.Fatalf("cookies = %#v, want one HttpOnly browser cookie", cookies)
	}
	if !strings.Contains(firstResponse.Body.String(), "Session ID") {
		t.Fatal("rendered page does not contain session data")
	}

	second := httptest.NewRequest(http.MethodGet, "/", nil)
	second.AddCookie(cookies[0])
	secondResponse := httptest.NewRecorder()
	server.route().ServeHTTP(secondResponse, second)
	if secondResponse.Code != http.StatusOK {
		t.Fatalf("second status = %d", secondResponse.Code)
	}
	if len(secondResponse.Result().Cookies()) != 0 {
		t.Fatal("valid browser cookie was unexpectedly replaced")
	}
	if !strings.Contains(secondResponse.Body.String(), "session-") || !strings.Contains(secondResponse.Body.String(), ">2<") {
		t.Fatalf("second page did not render retained session and page-load count: %s", secondResponse.Body.String())
	}
}

func TestHTMLRendersDegradedPageWhenSessionStoreFails(t *testing.T) {
	server := newTestServer(t, &testSessionStore{refreshErr: errors.New("Valkey unavailable")})
	response := httptest.NewRecorder()
	server.route().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
	if !strings.Contains(response.Body.String(), "unavailable") {
		t.Fatalf("degraded response did not render unavailable session values: %s", response.Body.String())
	}
}

func TestHealthAndReadinessReportValkeyState(t *testing.T) {
	store := newTestSessionStore(time.Now())
	server := newTestServer(t, store)

	health := httptest.NewRecorder()
	server.route().ServeHTTP(health, httptest.NewRequest(http.MethodGet, "/api/healthz", nil))
	if health.Code != http.StatusOK || !strings.Contains(health.Body.String(), `"connected":true`) {
		t.Fatalf("healthy response = %d %s", health.Code, health.Body.String())
	}

	store.pingErr = errors.New("Valkey unavailable")
	health = httptest.NewRecorder()
	server.route().ServeHTTP(health, httptest.NewRequest(http.MethodGet, "/api/healthz", nil))
	if health.Code != http.StatusOK || !strings.Contains(health.Body.String(), `"connected":false`) {
		t.Fatalf("disconnected health response = %d %s", health.Code, health.Body.String())
	}

	ready := httptest.NewRecorder()
	server.route().ServeHTTP(ready, httptest.NewRequest(http.MethodGet, "/api/readyz", nil))
	if ready.Code != http.StatusServiceUnavailable || !strings.Contains(ready.Body.String(), `"ready":false`) {
		t.Fatalf("disconnected readiness response = %d %s", ready.Code, ready.Body.String())
	}

	store.pingErr = nil
	server.data.Status.ready.Store(false)
	ready = httptest.NewRecorder()
	server.route().ServeHTTP(ready, httptest.NewRequest(http.MethodGet, "/api/readyz", nil))
	if ready.Code != http.StatusServiceUnavailable {
		t.Fatalf("manually disabled readiness status = %d", ready.Code)
	}
}

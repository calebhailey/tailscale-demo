package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
	"uuid"

	valkey "github.com/valkey-io/valkey-go"
)

const sessionTTL = 60 * time.Second

// SessionStore keeps the HTTP layer independent from Valkey so its failure
// behavior can be tested without a running data store.
type SessionStore interface {
	Check(context.Context) error
	Refresh(context.Context, string, string) (Session, error)
}

type ValkeyStore struct {
	address            string
	username           string
	password           string
	tlsConfig          *tls.Config
	configurationError error
	mu                 sync.Mutex
	client             valkey.Client
}

func NewValkeyStore(address string) *ValkeyStore {
	return newValkeyStore(address, "", "", false)
}

// NewValkeyStoreFromEnvironment configures the client used by a deployed app.
// Local development needs only VALKEY_ADDR; ElastiCache additionally provides
// TLS and ACL credentials through the systemd environment file.
func NewValkeyStoreFromEnvironment() *ValkeyStore {
	store := newValkeyStore(
		os.Getenv("VALKEY_ADDR"),
		os.Getenv("VALKEY_USERNAME"),
		os.Getenv("VALKEY_PASSWORD"),
		os.Getenv("VALKEY_TLS") == "true",
	)

	if passwordFile := os.Getenv("VALKEY_PASSWORD_FILE"); passwordFile != "" {
		password, err := os.ReadFile(passwordFile)
		if err != nil {
			store.configurationError = fmt.Errorf("reading VALKEY_PASSWORD_FILE: %w", err)
			return store
		}
		store.password = strings.TrimSuffix(strings.TrimSuffix(string(password), "\n"), "\r")
	}
	return store
}

func newValkeyStore(address, username, password string, useTLS bool) *ValkeyStore {
	if address == "" {
		address = "127.0.0.1:6379"
	}
	store := &ValkeyStore{address: address, username: username, password: password}
	if useTLS {
		host, _, err := net.SplitHostPort(address)
		if err != nil {
			store.configurationError = fmt.Errorf("parsing VALKEY_ADDR: %w", err)
			return store
		}
		store.tlsConfig = &tls.Config{MinVersion: tls.VersionTLS12, ServerName: host}
	}
	return store
}

func (store *ValkeyStore) getClient() (valkey.Client, error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	if store.configurationError != nil {
		return nil, store.configurationError
	}
	if store.client != nil {
		return store.client, nil
	}
	client, err := valkey.NewClient(valkey.ClientOption{
		InitAddress:       []string{store.address},
		ForceSingleClient: true,
		Dialer:            net.Dialer{Timeout: time.Second},
		TLSConfig:         store.tlsConfig,
		Username:          store.username,
		Password:          store.password,
	})
	if err != nil {
		return nil, err
	}
	store.client = client
	return client, nil
}

const refreshSessionScript = `
local session = KEYS[1]
local visitors = KEYS[2]
local now = tonumber(ARGV[1])
local sessionID = ARGV[2]
local hostname = ARGV[3]
local ttl = tonumber(ARGV[4])
local browserID = ARGV[5]

if redis.call('EXISTS', session) == 0 then
  redis.call('HSET', session, 'id', sessionID, 'started_at', ARGV[1])
end
local pageLoads = redis.call('HINCRBY', session, 'page_loads', 1)
redis.call('HSET', session, 'browser_id', browserID, 'serving_hostname', hostname)
redis.call('EXPIRE', session, ttl)
redis.call('ZADD', visitors, now, browserID)
redis.call('ZREMRANGEBYSCORE', visitors, '-inf', now - ttl * 1000)
local activeVisitors = redis.call('ZCARD', visitors)
return {redis.call('HGET', session, 'id'), redis.call('HGET', session, 'started_at'), pageLoads, activeVisitors, redis.call('TTL', session)}
`

func (store *ValkeyStore) Check(ctx context.Context) error {
	_, err := store.refresh(ctx, "readyz", "readyz", "demo:sessions:{demo}:readyz", "demo:sessions:{demo}")
	return err
}

func (store *ValkeyStore) Refresh(ctx context.Context, browserID, hostname string) (Session, error) {
	return store.refresh(ctx, browserID, hostname, "demo:sessions:{demo}:"+browserID, "demo:sessions:{demo}")
}

func (store *ValkeyStore) refresh(ctx context.Context, browserID, hostname, sessionKey, visitorsKey string) (Session, error) {
	client, err := store.getClient()
	if err != nil {
		return Session{}, err
	}
	now := time.Now().UTC()
	response := client.Do(ctx, client.B().Eval().
		Script(refreshSessionScript).
		Numkeys(2).
		Key(sessionKey, visitorsKey).
		Arg(
			strconv.FormatInt(now.UnixMilli(), 10),
			uuid.New().String(),
			hostname,
			strconv.FormatInt(int64(sessionTTL/time.Second), 10),
			browserID,
		).
		Build())
	values, err := response.ToArray()
	if err != nil {
		return Session{}, err
	}
	if len(values) != 5 {
		return Session{}, fmt.Errorf("unexpected session response length: %d", len(values))
	}

	id, err := values[0].ToString()
	if err != nil {
		return Session{}, err
	}
	startedAtText, err := values[1].ToString()
	if err != nil {
		return Session{}, err
	}
	startedAtMilliseconds, err := strconv.ParseInt(startedAtText, 10, 64)
	if err != nil {
		return Session{}, fmt.Errorf("parsing session start time: %w", err)
	}
	pageLoads, err := values[2].ToInt64()
	if err != nil {
		return Session{}, err
	}
	activeVisitors, err := values[3].ToInt64()
	if err != nil {
		return Session{}, err
	}
	ttlSeconds, err := values[4].ToInt64()
	if err != nil {
		return Session{}, err
	}

	return Session{
		BrowserID:       browserID,
		ID:              id,
		StartedAt:       time.UnixMilli(startedAtMilliseconds).UTC(),
		PageLoads:       pageLoads,
		ServingHostname: hostname,
		ActiveVisitors:  activeVisitors,
		ExpiresAt:       now.Add(time.Duration(ttlSeconds) * time.Second),
		ExpiresIn:       formatCountdown(ttlSeconds),
	}, nil
}

func formatCountdown(seconds int64) string {
	if seconds < 0 {
		seconds = 0
	}
	return fmt.Sprintf("%02d:%02d", seconds/60, seconds%60)
}

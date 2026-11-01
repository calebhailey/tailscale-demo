package main

import (
	"context"
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"text/template"
	"time"
	"uuid"
)

const (
	defaultHost       = "127.0.0.1"
	defaultPort       = 8080
	browserCookieName = "tailscale_demo_browser"

	imdsTokenURL = "http://169.254.169.254/latest/api/token"
	imdsTokenTTL = "300"

	PlatformKubernetes Platform = "kubernetes"
	PlatformDocker     Platform = "docker" // PlatformDocker represents any OCI container
	PlatformEC2        Platform = "ec2"
	PlatformLocal      Platform = "local"
)

//go:embed static
var website embed.FS

var logger = newLogger()

type Environment struct {
	Hostname     string   `json:"hostname"`
	Platform     Platform `json:"platform"`
	OS           string   `json:"os"`
	Architecture string   `json:"architecture"`
}

type Platform string

type Status struct {
	State     string `json:"state"`
	startedAt time.Time
	requests  atomic.Uint64
	errors    atomic.Uint64
	ready     atomic.Bool
}

type UserData map[string]any

// Session is the shared, short-lived browser state made available to HTML
// templates. It expires after sessionTTL without a page request.
type Session struct {
	BrowserID       string
	ID              string
	StartedAt       time.Time
	PageLoads       int64
	ServingHostname string
	ActiveVisitors  int64
	ExpiresAt       time.Time
	ExpiresIn       string
}

type TemplateData struct {
	Environment Environment
	Status      *Status
	User        UserData
	Session     *Session
}

type Middleware func(http.Handler) http.Handler

type Server struct {
	data        TemplateData
	middlewares []Middleware
	files       fs.FS
	sessions    SessionStore
}

type ResponseWriter struct {
	http.ResponseWriter
	status      int
	size        int
	wroteHeader bool
}

func (data TemplateData) Get(keypath string) any {
	parts := strings.Split(keypath, ".")
	if len(parts) == 0 {
		return nil
	}

	var value any
	switch parts[0] {
	case "env", "environment":
		value = data.Environment
	case "status":
		value = data.Status
	case "user":
		value = data.User
	case "session":
		value = data.Session
	default:
		return nil
	}

	for _, key := range parts[1:] {
		var ok bool
		value, ok = data.GetProperty(value, key)
		if !ok {
			return nil
		}
	}
	return value
}

func (data TemplateData) GetProperty(value any, key string) (any, bool) {
	switch value := value.(type) {
	case Environment:
		switch key {
		case "hostname":
			return value.Hostname, true
		case "os":
			return value.OS, true
		case "architecture":
			return value.Architecture, true
		case "platform":
			return value.Platform, true
		}
	case *Status:
		switch key {
		case "state":
			return value.State, true
		case "uptime":
			return value.Uptime(), true
		case "requests":
			return value.Requests(), true
		case "errors":
			return value.Errors(), true
		}
	case *Session:
		if value == nil {
			return nil, false
		}
		switch key {
		case "browser_id":
			return value.BrowserID, true
		case "id":
			return value.ID, true
		case "page_loads":
			return value.PageLoads, true
		case "active_visitors":
			return value.ActiveVisitors, true
		case "expires_in":
			return value.ExpiresIn, true
		case "expires_at":
			return value.ExpiresAt, true
		case "serving_hostname":
			return value.ServingHostname, true
		}
	case UserData:
		result, ok := value[key]
		return result, ok
	case map[string]any:
		result, ok := value[key]
		return result, ok
	}
	return nil, false
}

func (status *Status) Uptime() string {
	duration := time.Since(status.startedAt)
	return fmt.Sprintf(
		"%02d:%02d:%02d.%03d",
		int(duration.Hours()),
		int(duration.Minutes())%60,
		int(duration.Seconds())%60,
		duration.Milliseconds()%1000,
	)
}

func (status *Status) Requests() uint64 {
	return status.requests.Load()
}

func (status *Status) Errors() uint64 {
	return status.errors.Load()
}

func (status *Status) Ready() bool {
	return status.ready.Load()
}

func (status *Status) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		State    string `json:"state"`
		Uptime   string `json:"uptime"`
		Requests uint64 `json:"requests"`
		Errors   uint64 `json:"errors"`
		Ready    bool   `json:"ready"`
	}{
		State:    status.State,
		Uptime:   status.Uptime(),
		Requests: status.Requests(),
		Errors:   status.Errors(),
		Ready:    status.Ready(),
	})
}

func (s *Server) load(dataPath string) {
	hostname, err := os.Hostname()
	if err != nil {
		logger.Error("reading hostname", "error", err)
	}
	s.data.Environment = Environment{
		Hostname:     hostname,
		OS:           runtime.GOOS,
		Architecture: runtime.GOARCH,
		Platform:     detectPlatform(),
	}

	s.data.User = UserData{}
	if dataPath == "" {
		return
	}
	if filepath.IsAbs(dataPath) {
		logger.Error("loading data", "path", dataPath, "error", "path must be relative")
		return
	}

	source, err := os.ReadFile(dataPath)
	if err != nil {
		logger.Error("loading data", "path", dataPath, "error", err)
		return
	}
	if err := json.Unmarshal(source, &s.data.User); err != nil {
		logger.Error("parsing data", "path", dataPath, "error", err)
		s.data.User = UserData{}
	}
}

func (s *Server) use(middlewares ...Middleware) {
	s.middlewares = append(s.middlewares, middlewares...)
}

func (s Server) route() http.Handler {
	var mux = http.NewServeMux()
	mux.HandleFunc("/api/ping", s.handlePing)
	mux.HandleFunc("/api/healthz", s.handleHealthz)
	mux.HandleFunc("/api/readyz", s.handleReadyz)
	mux.Handle("/api/", http.NotFoundHandler())
	mux.HandleFunc("/", s.handleStatic)

	var handler = http.Handler(mux)
	for index := len(s.middlewares) - 1; index >= 0; index-- {
		handler = s.middlewares[index](handler)
	}
	return s.trackStatus(handler)
}

func (s Server) trackStatus(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.data.Status.requests.Add(1)
		response := &ResponseWriter{
			ResponseWriter: w,
			status:         http.StatusOK,
		}
		next.ServeHTTP(response, r)
		if response.status >= http.StatusBadRequest {
			s.data.Status.errors.Add(1)
		}
	})
}

func (s Server) handlePing(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("pong\n"))
}

func (s Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if err := json.NewEncoder(w).Encode(s.healthStatus()); err != nil {
		logger.Error("writing health response", "error", err)
	}
}

// handleReadyz is a demo-only readiness control. GET reports whether this
// instance should receive traffic; POST flips that state so a load balancer can
// remove and restore a live instance without stopping the process.
func (s Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")

	switch r.Method {
	case http.MethodGet:
		valkey := s.valkeyStatus()
		ready := s.data.Status.Ready() && valkey.Connected
		if !ready {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
		if err := json.NewEncoder(w).Encode(struct {
			Ready  bool         `json:"ready"`
			Valkey ValkeyStatus `json:"valkey"`
		}{Ready: ready, Valkey: valkey}); err != nil {
			logger.Error("writing readiness response", "error", err)
		}
		return
	case http.MethodPost:
		s.data.Status.ready.Store(!s.data.Status.Ready())
	default:
		w.Header().Set("Allow", "GET, POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	valkey := s.valkeyStatus()
	if err := json.NewEncoder(w).Encode(struct {
		Ready  bool         `json:"ready"`
		Valkey ValkeyStatus `json:"valkey"`
	}{
		Ready:  s.data.Status.Ready() && valkey.Connected,
		Valkey: valkey,
	}); err != nil {
		logger.Error("writing readiness response", "error", err)
	}
}

type ValkeyStatus struct {
	Connected bool `json:"connected"`
}

type HealthStatus struct {
	State    string       `json:"state"`
	Uptime   string       `json:"uptime"`
	Requests uint64       `json:"requests"`
	Errors   uint64       `json:"errors"`
	Ready    bool         `json:"ready"`
	Valkey   ValkeyStatus `json:"valkey"`
}

func (s Server) valkeyStatus() ValkeyStatus {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	return ValkeyStatus{Connected: s.sessions != nil && s.sessions.Check(ctx) == nil}
}

func (s Server) healthStatus() HealthStatus {
	return HealthStatus{
		State:    s.data.Status.State,
		Uptime:   s.data.Status.Uptime(),
		Requests: s.data.Status.Requests(),
		Errors:   s.data.Status.Errors(),
		Ready:    s.data.Status.Ready(),
		Valkey:   s.valkeyStatus(),
	}
}

func (s Server) handleStatic(w http.ResponseWriter, r *http.Request) {
	if !strings.HasSuffix(r.URL.Path, "/") && path.Ext(r.URL.Path) == "" {
		location := r.URL.Path + "/"
		if r.URL.RawQuery != "" {
			location += "?" + r.URL.RawQuery
		}
		http.Redirect(w, r, location, http.StatusMovedPermanently)
		return
	}

	filename := strings.TrimPrefix(path.Clean("/"+r.URL.Path), "/")
	if strings.HasSuffix(r.URL.Path, "/") {
		filename = path.Join(filename, "index.html")
	}
	if path.Ext(filename) != ".html" {
		http.FileServer(http.FS(s.files)).ServeHTTP(w, r)
		return
	}

	browserID, setBrowserCookie := browserIDFromRequest(r)
	ctx, cancel := context.WithTimeout(r.Context(), time.Second)
	defer cancel()
	var session Session
	var sessionErr error
	if s.sessions == nil {
		sessionErr = fmt.Errorf("session store is unavailable")
	} else {
		session, sessionErr = s.sessions.Refresh(ctx, browserID, s.data.Environment.Hostname)
	}
	if sessionErr != nil {
		logger.Error("refreshing session", "error", sessionErr)
	} else if setBrowserCookie {
		http.SetCookie(w, &http.Cookie{
			Name:     browserCookieName,
			Value:    browserID,
			Path:     "/",
			HttpOnly: true,
			SameSite: http.SameSiteLaxMode,
		})
	}

	source, err := fs.ReadFile(s.files, filename)
	if err != nil {
		http.NotFound(w, r)
		return
	}

	data := s.data
	if sessionErr == nil {
		data.Session = &session
	}
	tmpl, err := template.New(path.Base(filename)).Funcs(template.FuncMap{
		"get": data.Get,
	}).Parse(string(source))
	if err != nil {
		logger.Error("parsing template", "path", filename, "error", err)
		http.Error(w, "template error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	// The rendered document includes per-instance and session information. Do
	// not let a browser reuse a prior document instead of issuing a request to
	// the load-balanced application fleet.
	w.Header().Set("Cache-Control", "no-store")
	if err := tmpl.Execute(w, data); err != nil {
		logger.Error("rendering template", "path", filename, "error", err)
	}
}

func browserIDFromRequest(r *http.Request) (string, bool) {
	cookie, err := r.Cookie(browserCookieName)
	if err == nil {
		if id, err := uuid.Parse(cookie.Value); err == nil {
			return id.String(), false
		}
	}
	return uuid.New().String(), true
}

func (w *ResponseWriter) WriteHeader(status int) {
	if w.wroteHeader {
		return
	}
	w.status = status
	w.wroteHeader = true
	w.ResponseWriter.WriteHeader(status)
}

func (w *ResponseWriter) Write(body []byte) (int, error) {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
	size, err := w.ResponseWriter.Write(body)
	w.size += size
	return size, err
}

// FUNCTIONS ==================================================================

func main() {
	var host string
	var bind string
	var dataPath string
	var port int

	flag.StringVar(&host, "host", defaultHost, "host to listen on when --bind is omitted")
	flag.IntVar(&port, "port", defaultPort, "port to listen on when --bind is omitted")
	flag.StringVar(&bind, "bind", "", "complete listen address; overrides --host and --port")
	flag.StringVar(&dataPath, "data", "", "relative path to a JSON object")
	flag.Parse()

	listenAddress := bind
	if listenAddress == "" {
		listenAddress = fmt.Sprintf("%s:%d", host, port)
	}

	staticFiles, err := fs.Sub(website, "static")
	if err != nil {
		logger.Error("preparing embedded website", "error", err)
		os.Exit(1)
	}

	app := Server{
		data: TemplateData{
			Status: &Status{
				State:     "ok",
				startedAt: time.Now(),
			},
		},
		files:    staticFiles,
		sessions: NewValkeyStoreFromEnvironment(),
	}
	app.data.Status.ready.Store(true)
	app.load(dataPath)
	app.use(RequestID, RequestLogger)

	logger.Info("listening", "address", listenAddress)
	if err := http.ListenAndServe(listenAddress, app.route()); err != nil {
		logger.Error("server stopped", "error", err)
		os.Exit(1)
	}
}

func RequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestID := r.Header.Get("X-Request-ID")
		if requestID == "" {
			requestID = uuid.New().String()
		}
		r.Header.Set("X-Request-ID", requestID)
		w.Header().Set("X-Request-ID", requestID)
		next.ServeHTTP(w, r)
	})
}

func RequestLogger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		startedAt := time.Now()
		response := &ResponseWriter{
			ResponseWriter: w,
			status:         http.StatusOK,
		}

		next.ServeHTTP(response, r)

		logger.Info("",
			"id", r.Header.Get("X-Request-ID"),
			"method", r.Method,
			"status", response.status,
			"path", r.URL.Path,
			"bytes", response.size,
			"duration", time.Since(startedAt).String(),
		)
	})
}

func newLogger() *slog.Logger {
	return slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{
		ReplaceAttr: func(_ []string, attr slog.Attr) slog.Attr {
			if attr.Key == slog.TimeKey {
				return slog.String(slog.TimeKey, attr.Value.Time().UTC().Format(time.RFC3339))
			}
			return attr
		},
	}))
}

func detectPlatform() Platform {
	if os.Getenv("KUBERNETES_SERVICE_HOST") != "" {
		return PlatformKubernetes
	}

	if _, err := os.Stat("/.dockerenv"); err == nil {
		return PlatformDocker
	}

	if _, err := os.Stat("/run/.containerenv"); err == nil {
		return PlatformDocker
	}

	if cgroup, err := os.ReadFile("/proc/1/cgroup"); err == nil {
		markers := []string{"docker", "containerd", "kubepods", "libpod", "crio"}
		value := strings.ToLower(string(cgroup))
		for _, marker := range markers {
			if strings.Contains(value, marker) {
				return PlatformDocker
			}
		}
	}

	if detectEC2() {
		return PlatformEC2
	}

	return PlatformLocal
}

func detectEC2() bool {
	var client = &http.Client{
		Timeout: time.Second,
		Transport: &http.Transport{
			Proxy: nil,
		},
	}
	var request *http.Request
	var response *http.Response
	var err error
	if request, err = http.NewRequest(http.MethodPut, imdsTokenURL, nil); err != nil {
		return false
	}
	request.Header.Set("X-aws-ec2-metadata-token-ttl-seconds", imdsTokenTTL)
	if response, err = client.Do(request); err != nil {
		return false
	}
	defer response.Body.Close()
	return response.StatusCode == http.StatusOK
}

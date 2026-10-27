package app

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"log/slog"
	"net/http"
	"time"
)

func (s *Service) serve(ctx context.Context) error {
	srv := &http.Server{
		Addr:              s.cfg.Listen,
		Handler:           s.routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	errCh := make(chan error, 1)
	go func() {
		slog.Info("dashboard listening", "addr", s.cfg.Listen)
		err := srv.ListenAndServe()
		if err != nil && err != http.ErrServerClosed {
			errCh <- err
			return
		}
		errCh <- nil
	}()
	select {
	case <-ctx.Done():
		shut, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shut)
		return nil
	case err := <-errCh:
		return err
	}
}

func (s *Service) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		s.render(w, "inbox", "", "")
	})
	mux.HandleFunc("GET /history", func(w http.ResponseWriter, r *http.Request) {
		s.render(w, "history", r.URL.Query().Get("q"), r.URL.Query().Get("kind"))
	})
	mux.HandleFunc("GET /versions", func(w http.ResponseWriter, r *http.Request) {
		s.render(w, "versions", "", "")
	})
	mux.HandleFunc("POST /seen", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		s.markRead(r.FormValue("id"))
		http.Redirect(w, r, nextPath(r.FormValue("next")), http.StatusSeeOther)
	})
	mux.HandleFunc("POST /seen/all", func(w http.ResponseWriter, r *http.Request) {
		s.markAllRead()
		http.Redirect(w, r, "/", http.StatusSeeOther)
	})
	mux.HandleFunc("POST /refresh", func(w http.ResponseWriter, r *http.Request) {
		if !s.demo && s.engine != nil {
			s.engine.ForceRefresh()
			go s.poll(context.Background())
		}
		http.Redirect(w, r, "/", http.StatusSeeOther)
	})
	mux.HandleFunc("POST /versions/check", func(w http.ResponseWriter, r *http.Request) {
		if !s.demo {
			go s.checkVersions(context.Background(), false)
		}
		http.Redirect(w, r, "/versions", http.StatusSeeOther)
	})
	mux.HandleFunc("POST /versions/repo", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		if !s.demo {
			account, repo := r.FormValue("account"), r.FormValue("repo")
			go s.refreshRepo(context.Background(), account, repo)
		}
		http.Redirect(w, r, "/versions", http.StatusSeeOther)
	})
	mux.HandleFunc("POST /versions/seen", func(w http.ResponseWriter, r *http.Request) {
		s.markVulnsSeen()
		http.Redirect(w, r, "/versions", http.StatusSeeOther)
	})
	return s.protect(mux)
}

func (s *Service) render(w http.ResponseWriter, section, query, kind string) {
	if err := renderPage(w, section, s.page(section, query, kind)); err != nil {
		slog.Error("render", "err", err)
		http.Error(w, "render failed", http.StatusInternalServerError)
	}
}

func (s *Service) markRead(id string) {
	if id == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.hist.MarkRead(id) && !s.demo {
		if err := s.store.SaveHistory(s.hist); err != nil {
			slog.Error("save history", "err", err)
		}
	}
}

func (s *Service) markAllRead() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.hist.MarkAllRead() && !s.demo {
		if err := s.store.SaveHistory(s.hist); err != nil {
			slog.Error("save history", "err", err)
		}
	}
}

func (s *Service) markVulnsSeen() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.unseen = map[string]bool{}
	if !s.demo {
		s.saveVersionsLocked()
	}
}

func (s *Service) protect(next http.Handler) http.Handler {
	user := s.cfg.DashboardUser
	pass := s.cfg.DashboardPassword
	if user == "" && pass == "" {
		return next
	}
	expectUser := sha256.Sum256([]byte(user))
	expectPass := sha256.Sum256([]byte(pass))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			next.ServeHTTP(w, r)
			return
		}
		gotUser, gotPass, ok := r.BasicAuth()
		u := sha256.Sum256([]byte(gotUser))
		p := sha256.Sum256([]byte(gotPass))
		if !ok || subtle.ConstantTimeCompare(u[:], expectUser[:]) != 1 || subtle.ConstantTimeCompare(p[:], expectPass[:]) != 1 {
			w.Header().Set("WWW-Authenticate", `Basic realm="pullwatch"`)
			http.Error(w, "authentication required", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func nextPath(raw string) string {
	switch raw {
	case "/history", "/versions":
		return raw
	default:
		return "/"
	}
}

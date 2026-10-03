package server

import (
	"log"
	"net/http"
	"path/filepath"

	"golang.org/x/net/webdav"

	"github.com/YLing2024/davbox/internal/account"
)

// isWriteMethod 列出只读账号需要拒绝的动词。
// LOCK/UNLOCK 也会改变服务端状态（并可能创建资源），一并阻断。
func isWriteMethod(method string) bool {
	switch method {
	case http.MethodPut, http.MethodDelete, "MKCOL", "MOVE", "COPY", "PROPPATCH", "LOCK", "UNLOCK":
		return true
	}
	return false
}

// davFSFor 为账号构造带死属性持久化的文件系统。
// sidecar 放在账号 root 之外，保证不会出现在客户端可见目录里。
func (s *Server) davFSFor(acct account.Account) webdav.FileSystem {
	return newDeadPropFS(acct.Root, filepath.Join(s.dataDir, "davprops", acct.User))
}

func writeAuthChallenge(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", `Basic realm="davbox"`)
	writeError(w, http.StatusUnauthorized, "未认证")
}

// lockSystem 为每个账号复用同一个内存锁系统。
func (s *Server) lockSystem(user string) webdav.LockSystem {
	s.davMu.Lock()
	defer s.davMu.Unlock()
	ls := s.locks[user]
	if ls == nil {
		ls = webdav.NewMemLS()
		s.locks[user] = ls
	}
	return ls
}

// forgetLocks 在账号被删除后释放其锁系统。
func (s *Server) forgetLocks(user string) {
	s.davMu.Lock()
	defer s.davMu.Unlock()
	delete(s.locks, user)
}

// handleDAV 完成认证、只读检查后交给官方 webdav.Handler。
func (s *Server) handleDAV(w http.ResponseWriter, r *http.Request, user string) {
	authUser, pass, ok := r.BasicAuth()
	if !ok || authUser != user {
		writeAuthChallenge(w)
		return
	}
	acct, ok := s.store.Authenticate(user, pass)
	if !ok {
		writeAuthChallenge(w)
		return
	}
	if acct.Readonly && isWriteMethod(r.Method) {
		writeError(w, http.StatusForbidden, "只读账号")
		return
	}

	// 官方 Handler 的 Prefix 是 /<user>/，路径 /<user>（无尾斜杠）对不上会 404。
	// 许多客户端（含本仓库同步 App）对账号根发出 PROPFIND /<user>。
	if r.URL.Path == "/"+user {
		rr := r.Clone(r.Context())
		u := *r.URL
		u.Path = "/" + user + "/"
		if u.RawPath != "" {
			u.RawPath = "/" + user + "/"
		}
		rr.URL = &u
		r = rr
	}

	h := &webdav.Handler{
		Prefix:     "/" + user + "/",
		FileSystem: s.davFSFor(acct),
		LockSystem: s.lockSystem(user),
		Logger: func(req *http.Request, err error) {
			if err != nil {
				// 只记录方法、路径与错误，绝不触碰 Authorization 头。
				log.Printf("webdav %s %s: %v", req.Method, req.URL.Path, err)
			}
		},
	}
	h.ServeHTTP(w, r)
}

// davHandlerFor 供测试直接拿到某账号的处理器。
func (s *Server) davHandlerFor(acct account.Account) http.Handler {
	return &webdav.Handler{
		Prefix:     "/" + acct.User + "/",
		FileSystem: s.davFSFor(acct),
		LockSystem: s.lockSystem(acct.User),
	}
}

package server

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/bcrypt"

	"github.com/YLing2024/davbox/internal/account"
	"github.com/YLing2024/davbox/internal/auth"
)

const testAdminPass = "test-admin-pass"

func newTestServer(t *testing.T) (*Server, *account.Store, string) {
	t.Helper()
	dir := t.TempDir()
	store, err := account.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(testAdminPass), bcrypt.MinCost)
	if err != nil {
		t.Fatal(err)
	}
	signer := auth.NewSigner([]byte("0123456789abcdef0123456789abcdef"))
	return New(Config{DataDir: dir, Store: store, AdminHash: hash, Signer: signer}), store, dir
}

func request(s *Server, method, target, user, pass string, body io.Reader, headers map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, body)
	if user != "" {
		req.SetBasicAuth(user, pass)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	return rec
}

func TestDAVUnauthenticatedChallenge(t *testing.T) {
	s, store, _ := newTestServer(t)
	_, _, _ = store.Create("app1", false, "")

	rec := request(s, "PROPFIND", "/app1/", "", "", nil, map[string]string{"Depth": "0"})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("未认证应为 401，实际 %d", rec.Code)
	}
	if got := rec.Header().Get("WWW-Authenticate"); got != `Basic realm="davbox"` {
		t.Fatalf("缺少或错误的 WWW-Authenticate: %q", got)
	}
}

func TestDAVWrongPassword(t *testing.T) {
	s, store, _ := newTestServer(t)
	_, _, _ = store.Create("app1", false, "")

	rec := request(s, "PROPFIND", "/app1/", "app1", "nope", nil, map[string]string{"Depth": "0"})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("错口令应为 401，实际 %d", rec.Code)
	}
	if rec.Header().Get("WWW-Authenticate") == "" {
		t.Fatal("错口令响应也应带 WWW-Authenticate")
	}
}

func TestDAVDisabledAccountRejected(t *testing.T) {
	s, store, _ := newTestServer(t)
	_, pass, _ := store.Create("app1", false, "")
	disabled := true
	if _, err := store.Update("app1", account.Patch{Disabled: &disabled}); err != nil {
		t.Fatal(err)
	}

	rec := request(s, "PROPFIND", "/app1/", "app1", pass, nil, map[string]string{"Depth": "0"})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("停用账号应为 401，实际 %d", rec.Code)
	}
}

func TestDAVCrossAccount(t *testing.T) {
	s, store, _ := newTestServer(t)
	_, passA, _ := store.Create("app1", false, "")
	_, _, _ = store.Create("app2", false, "")

	rec := request(s, "PROPFIND", "/app2/", "app1", passA, nil, map[string]string{"Depth": "0"})
	if rec.Code != http.StatusUnauthorized && rec.Code != http.StatusForbidden && rec.Code != http.StatusNotFound {
		t.Fatalf("跨账号应为 401/403/404，实际 %d", rec.Code)
	}
}

func TestDAVPathEscapeRejected(t *testing.T) {
	s, store, _ := newTestServer(t)
	_, pass, _ := store.Create("app1", false, "")

	cases := []string{
		"/app1/%2e%2e/secret",
		"/app1/..%2fsecret",
		"/app1/%2E%2E/secret",
	}
	for _, target := range cases {
		rec := request(s, "PROPFIND", target, "app1", pass, nil, map[string]string{"Depth": "0"})
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("路径 %s 应为 400，实际 %d", target, rec.Code)
		}
	}
}

func TestDAVSixVerbs(t *testing.T) {
	s, store, dir := newTestServer(t)
	_, pass, _ := store.Create("app1", false, "")

	rec := request(s, "MKCOL", "/app1/notes", "app1", pass, nil, nil)
	if rec.Code != http.StatusCreated {
		t.Fatalf("MKCOL 应为 201，实际 %d", rec.Code)
	}

	rec = request(s, http.MethodPut, "/app1/notes/a.txt", "app1", pass, strings.NewReader("hello-davbox"), nil)
	if rec.Code != http.StatusCreated {
		t.Fatalf("PUT 应为 201，实际 %d", rec.Code)
	}

	rec = request(s, http.MethodGet, "/app1/notes/a.txt", "app1", pass, nil, nil)
	if rec.Code != http.StatusOK || rec.Body.String() != "hello-davbox" {
		t.Fatalf("GET 应为 200 且内容一致，实际 %d %q", rec.Code, rec.Body.String())
	}

	rec = request(s, "PROPFIND", "/app1/", "app1", pass, nil, map[string]string{"Depth": "0"})
	if rec.Code != 207 {
		t.Fatalf("PROPFIND Depth:0 应为 207，实际 %d", rec.Code)
	}
	rec = request(s, "PROPFIND", "/app1", "app1", pass, nil, map[string]string{"Depth": "0"})
	if rec.Code != 207 {
		t.Fatalf("PROPFIND 账号根无尾斜杠应为 207，实际 %d %s", rec.Code, rec.Body.String())
	}
	rec = request(s, "PROPFIND", "/app1/notes/", "app1", pass, nil, map[string]string{"Depth": "1"})
	if rec.Code != 207 {
		t.Fatalf("PROPFIND Depth:1 应为 207，实际 %d", rec.Code)
	}

	rec = request(s, "MOVE", "/app1/notes/a.txt", "app1", pass, nil, map[string]string{
		"Destination": "http://example.com/app1/notes/b.txt",
	})
	if rec.Code != http.StatusCreated && rec.Code != http.StatusNoContent {
		t.Fatalf("MOVE 应为 201/204，实际 %d", rec.Code)
	}

	// 内容确实只落在 app1 的 root 下。
	if _, err := os.Stat(filepath.Join(dir, "data", "app1", "notes", "b.txt")); err != nil {
		t.Fatalf("MOVE 结果应落在账号 root: %v", err)
	}

	rec = request(s, http.MethodDelete, "/app1/notes/b.txt", "app1", pass, nil, nil)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("DELETE 应为 204，实际 %d", rec.Code)
	}
}

func TestDAVReadonlyAccount(t *testing.T) {
	s, store, dir := newTestServer(t)
	_, pass, _ := store.Create("ro", true, "")
	if err := os.WriteFile(filepath.Join(dir, "data", "ro", "readme.txt"), []byte("ok"), 0o644); err != nil {
		t.Fatal(err)
	}

	rec := request(s, http.MethodPut, "/ro/x.txt", "ro", pass, strings.NewReader("nope"), nil)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("只读账号 PUT 应为 403，实际 %d", rec.Code)
	}
	rec = request(s, "MKCOL", "/ro/dir", "ro", pass, nil, nil)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("只读账号 MKCOL 应为 403，实际 %d", rec.Code)
	}
	rec = request(s, http.MethodGet, "/ro/readme.txt", "ro", pass, nil, nil)
	if rec.Code != http.StatusOK || rec.Body.String() != "ok" {
		t.Fatalf("只读账号 GET 应为 200，实际 %d %q", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "data", "ro", "x.txt")); !os.IsNotExist(err) {
		t.Fatal("只读账号不应产生文件")
	}
}

func TestAdminAPIExplicitFlow(t *testing.T) {
	s, _, dir := newTestServer(t)

	// 错口令
	rec := request(s, http.MethodPost, "/api/admin/login", "", "", strings.NewReader(`{"password":"bad"}`), nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("错口令应为 401，实际 %d", rec.Code)
	}

	// 正确口令，取 cookie
	rec = request(s, http.MethodPost, "/api/admin/login", "", "", strings.NewReader(`{"password":"`+testAdminPass+`"}`), nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("正确口令应为 200，实际 %d", rec.Code)
	}
	cookies := rec.Result().Cookies()
	if len(cookies) == 0 {
		t.Fatal("登录后应下发 cookie")
	}

	// 带 cookie 访问列表
	rec = doWithCookie(s, http.MethodGet, "/api/admin/accounts", cookies, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("列表应为 200，实际 %d", rec.Code)
	}

	// 无 cookie 访问列表
	rec = request(s, http.MethodGet, "/api/admin/accounts", "", "", nil, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("未登录列表应为 401，实际 %d", rec.Code)
	}

	// 建账号
	rec = doWithCookie(s, http.MethodPost, "/api/admin/accounts", cookies, strings.NewReader(`{"user":"newapp","readonly":false}`))
	if rec.Code != http.StatusCreated {
		t.Fatalf("建账号应为 201，实际 %d", rec.Code)
	}
	var created struct {
		User string `json:"user"`
		Pass string `json:"pass"`
		URL  string `json:"url"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if created.User != "newapp" || created.Pass == "" || created.URL == "" {
		t.Fatalf("建账号响应不完整: %+v", created)
	}

	// 换口令后旧口令失效
	var newPass string
	rec = doWithCookie(s, http.MethodPost, "/api/admin/accounts/newapp/rotate", cookies, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("换口令应为 200，实际 %d", rec.Code)
	}
	{
		var rot struct {
			Pass string `json:"pass"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &rot); err != nil {
			t.Fatal(err)
		}
		newPass = rot.Pass
	}
	if _, ok := s.store.Authenticate("newapp", created.Pass); ok {
		t.Fatal("旧口令应失效")
	}
	if _, ok := s.store.Authenticate("newapp", newPass); !ok {
		t.Fatal("新口令应可用")
	}

	// 删除后列表消失、目录仍在
	rec = doWithCookie(s, http.MethodDelete, "/api/admin/accounts/newapp", cookies, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("删除应为 200，实际 %d", rec.Code)
	}
	if _, ok := s.store.Get("newapp"); ok {
		t.Fatal("删除后列表应消失")
	}
	if _, err := os.Stat(filepath.Join(dir, "data", "newapp")); err != nil {
		t.Fatalf("删除后目录应保留: %v", err)
	}
}

func TestClientAPIExplicitFlow(t *testing.T) {
	s, store, _ := newTestServer(t)
	_, pass, _ := store.Create("app1", false, "")

	// 登录
	rec := request(s, http.MethodPost, "/api/client/login", "", "", strings.NewReader(`{"user":"app1","pass":"`+pass+`"}`), nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("client 登录应为 200，实际 %d", rec.Code)
	}
	cookies := rec.Result().Cookies()

	// 上传
	rec = doWithCookie(s, http.MethodPut, "/api/client/raw/hello.txt", cookies, strings.NewReader("client-body"))
	if rec.Code != http.StatusCreated {
		t.Fatalf("上传应为 201，实际 %d", rec.Code)
	}

	// 列表
	rec = doWithCookie(s, http.MethodGet, "/api/client/list?path=/", cookies, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("列表应为 200，实际 %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "hello.txt") {
		t.Fatalf("列表应包含上传的文件: %s", rec.Body.String())
	}

	// 下载内容一致
	rec = doWithCookie(s, http.MethodGet, "/api/client/raw/hello.txt", cookies, nil)
	if rec.Code != http.StatusOK || rec.Body.String() != "client-body" {
		t.Fatalf("下载应为 200 且内容一致，实际 %d %q", rec.Code, rec.Body.String())
	}

	// 重命名
	rec = doWithCookie(s, http.MethodPost, "/api/client/rename", cookies, strings.NewReader(`{"from":"/hello.txt","to":"/renamed.txt"}`))
	if rec.Code != http.StatusOK {
		t.Fatalf("重命名应为 200，实际 %d", rec.Code)
	}

	// 删除
	rec = doWithCookie(s, http.MethodDelete, "/api/client/entry?path=/renamed.txt", cookies, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("删除应为 200，实际 %d", rec.Code)
	}

	// 路径逃逸
	rec = doWithCookie(s, http.MethodGet, "/api/client/list?path=/../", cookies, nil)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("逃逸路径应为 400，实际 %d", rec.Code)
	}
}

func doWithCookie(s *Server, method, target string, cookies []*http.Cookie, body io.Reader) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, body)
	for _, c := range cookies {
		req.AddCookie(c)
	}
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	return rec
}

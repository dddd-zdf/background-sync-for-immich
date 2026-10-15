package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// fakeImmich checks the multipart request the proxy builds and answers like Immich.
func fakeImmich(t *testing.T, status int, body string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/assets" || r.Method != http.MethodPost {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		if got := r.Header.Get("x-api-key"); got != "key123" {
			t.Errorf("api key = %q", got)
		}
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			t.Fatalf("multipart: %v", err)
		}
		want := map[string]string{
			"fileCreatedAt":  "2026-10-14T10:00:00Z",
			"fileModifiedAt": "2026-10-14T11:00:00Z",
			"isFavorite":     "true",
			"filename":       "IMG 0001 é.HEIC",
		}
		for k, v := range want {
			if got := r.FormValue(k); got != v {
				t.Errorf("%s = %q, want %q", k, got, v)
			}
		}
		file, header, err := r.FormFile("assetData")
		if err != nil {
			t.Fatalf("assetData: %v", err)
		}
		data, _ := io.ReadAll(file)
		if string(data) != "PHOTO-BYTES" || header.Filename != "IMG 0001 é.HEIC" || header.Header.Get("Content-Type") != "image/heic" {
			t.Errorf("file part = %q %q %q", data, header.Filename, header.Header.Get("Content-Type"))
		}
		w.WriteHeader(status)
		io.WriteString(w, body)
	}))
}

func upload(t *testing.T, immich string) *http.Response {
	proxy := httptest.NewServer(uploadHandler(immich, http.DefaultClient))
	defer proxy.Close()
	req, _ := http.NewRequest(http.MethodPost, proxy.URL, strings.NewReader("PHOTO-BYTES"))
	req.Header.Set("x-api-key", "key123")
	req.Header.Set("X-Filename", "IMG%200001%20%C3%A9.HEIC")
	req.Header.Set("X-Content-Type", "image/heic")
	req.Header.Set("X-File-Created-At", "2026-10-14T10:00:00Z")
	req.Header.Set("X-File-Modified-At", "2026-10-14T11:00:00Z")
	req.Header.Set("X-Is-Favorite", "true")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func TestCreated(t *testing.T) {
	immich := fakeImmich(t, 201, `{"id":"11111111-2222-4333-8444-555555555555","status":"created"}`)
	defer immich.Close()
	resp := upload(t, immich.URL)
	if resp.StatusCode != 201 || resp.Header.Get(hAssetID) != "11111111-2222-4333-8444-555555555555" ||
		resp.Header.Get(hResult) != "created" || resp.Header.Get(hStatus) != "201" {
		t.Errorf("got %d %v", resp.StatusCode, resp.Header)
	}
}

func TestDuplicateStillReturnsID(t *testing.T) {
	immich := fakeImmich(t, 200, `{"id":"abc","status":"duplicate"}`)
	defer immich.Close()
	resp := upload(t, immich.URL)
	if resp.StatusCode != 200 || resp.Header.Get(hAssetID) != "abc" || resp.Header.Get(hResult) != "duplicate" {
		t.Errorf("got %d %v", resp.StatusCode, resp.Header)
	}
}

func TestErrorPassesThrough(t *testing.T) {
	immich := fakeImmich(t, 401, `{"message":"Invalid API key","statusCode":401}`)
	defer immich.Close()
	resp := upload(t, immich.URL)
	if resp.StatusCode != 401 || resp.Header.Get(hAssetID) != "" || resp.Header.Get(hError) != "Invalid API key" {
		t.Errorf("got %d %v", resp.StatusCode, resp.Header)
	}
}

func TestPreflightIs501(t *testing.T) {
	rec := httptest.NewRecorder()
	uploadHandler("http://unused", http.DefaultClient)(rec, httptest.NewRequest(http.MethodOptions, "/api/assets/background", nil))
	if rec.Code != http.StatusNotImplemented {
		t.Errorf("OPTIONS = %d", rec.Code)
	}
}

// TestReplace: after the edited version uploads, the old asset's albums are copied and it is trashed.
func TestReplace(t *testing.T) {
	var calls []string
	immich := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method + " " + r.URL.Path {
		case "POST /api/assets":
			w.WriteHeader(201)
			io.WriteString(w, `{"id":"new","status":"created"}`)
		case "PUT /api/assets/copy", "DELETE /api/assets":
			var body map[string]any
			json.NewDecoder(r.Body).Decode(&body)
			if r.Header.Get("x-api-key") != "key123" {
				t.Errorf("api key missing on %s", r.URL.Path)
			}
			b, _ := json.Marshal(body)
			calls = append(calls, r.Method+" "+string(b))
			w.WriteHeader(204)
		default:
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
	}))
	defer immich.Close()
	proxy := httptest.NewServer(uploadHandler(immich.URL, http.DefaultClient))
	defer proxy.Close()

	for _, old := range []string{"old", "new"} {
		calls = nil
		req, _ := http.NewRequest(http.MethodPost, proxy.URL, strings.NewReader("PHOTO-BYTES"))
		req.Header.Set("x-api-key", "key123")
		req.Header.Set("X-Replace-Asset-Id", old)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		if old == "new" {
			// Immich matched the upload to the old asset itself: nothing to replace.
			if len(calls) != 0 || resp.Header.Get(hReplaced) != "" {
				t.Errorf("same asset: calls %v, header %q", calls, resp.Header.Get(hReplaced))
			}
			continue
		}
		want := []string{
			`PUT {"favorite":false,"sourceId":"old","targetId":"new"}`,
			`DELETE {"ids":["old"]}`,
		}
		if strings.Join(calls, "|") != strings.Join(want, "|") || resp.Header.Get(hReplaced) != "ok" {
			t.Errorf("calls %v, header %q", calls, resp.Header.Get(hReplaced))
		}
	}
}

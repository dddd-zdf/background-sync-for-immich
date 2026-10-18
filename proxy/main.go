// background-sync-server turns PhotoKit background uploads into Immich uploads.
//
// PhotoKit sends the photo as the raw request body, with our metadata in headers.
// Immich only accepts multipart/form-data on POST /api/assets, so this streams the
// body into a multipart request (never holding the file in memory) and reports the
// result back in response headers, the only part of the response PhotoKit keeps.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

func main() {
	listen := envOr("LISTEN_ADDR", "127.0.0.1:2284")
	immich := strings.TrimRight(envOr("IMMICH_URL", "http://127.0.0.1:2283"), "/")

	mux := http.NewServeMux()
	upload := uploadHandler(immich, http.DefaultClient)
	debugLog := logHandler(immich, http.DefaultClient)
	// Same path as uploads, so no extra reverse proxy route: the app's optional debug log.
	mux.HandleFunc("/api/assets/background", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Debug-Log") != "" {
			debugLog(w, r)
			return
		}
		upload(w, r)
	})
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok\n") })

	log.Printf("listening on %s, Immich at %s", listen, immich)
	server := &http.Server{Addr: listen, Handler: mux, ReadHeaderTimeout: 30 * time.Second}
	log.Fatal(server.ListenAndServe())
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// Response headers read by the upload extension (PhotoKit lowercases them).
const (
	hAssetID  = "X-Immich-Asset-Id" // Immich asset ID, set on success (created or duplicate)
	hStatus   = "X-Immich-Status"   // Immich HTTP status code
	hResult   = "X-Immich-Result"   // Immich's "created" / "duplicate" / "replaced"
	hError    = "X-Immich-Error"    // short error text on failure
	hReplaced = "X-Immich-Replaced" // result of X-Replace-Asset-Id: "ok" or what failed
	hStacked  = "X-Immich-Stacked"  // result of X-Stack-Original-Id: "ok" or what failed
	hRestored = "X-Immich-Restored" // an original matched an existing asset: restore from trash, "ok" or what failed
)

func uploadHandler(immich string, client *http.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodOptions:
			// PhotoKit preflight: 501 means "no resumable uploads", so it sends one plain request.
			w.WriteHeader(http.StatusNotImplemented)
			return
		case http.MethodPost, http.MethodPut:
		default:
			w.Header().Set("Allow", "OPTIONS, POST, PUT")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}

		fields, filename, contentType := uploadFields(r.Header)
		body, writer := io.Pipe()
		mp := multipart.NewWriter(writer)
		go func() {
			writer.CloseWithError(writeMultipart(mp, fields, filename, contentType, r.Body))
		}()

		req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, immich+"/api/assets", body)
		if err != nil {
			fail(w, http.StatusInternalServerError, err.Error())
			return
		}
		req.Header.Set("Content-Type", mp.FormDataContentType())
		req.Header.Set("Accept", "application/json")
		req.Header.Set("x-api-key", r.Header.Get("x-api-key"))

		start := time.Now()
		resp, err := client.Do(req)
		if err != nil {
			log.Printf("upload %q: forward failed: %v", filename, err)
			fail(w, http.StatusBadGateway, "immich unreachable")
			return
		}
		defer resp.Body.Close()
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))

		var result struct {
			ID      string `json:"id"`
			Status  string `json:"status"`
			Message any    `json:"message"`
		}
		_ = json.Unmarshal(respBody, &result)
		w.Header().Set(hStatus, fmt.Sprint(resp.StatusCode))
		if resp.StatusCode/100 == 2 && result.ID != "" {
			w.Header().Set(hAssetID, result.ID)
			w.Header().Set(hResult, result.Status)
			// Immich also matches uploads to trashed assets. An edit's original matched in the trash
			// (e.g. deleted in an earlier cleanup) must come back, or it would be stacked under the
			// edit and then emptied with the trash. Restoring an asset that isn't trashed does nothing.
			if part := r.Header.Get("X-Upload-Part"); result.Status == "duplicate" && (part == "original" || part == "originalVideo") {
				code, msg, err := immichJSON(r.Context(), client, http.MethodPost, immich+"/api/trash/restore/assets", r.Header.Get("x-api-key"), map[string]any{"ids": []string{result.ID}})
				outcome := "ok"
				if err != nil || code/100 != 2 {
					outcome = fmt.Sprintf("HTTP %d %s %v", code, msg, err)
				}
				w.Header().Set(hRestored, headerSafe(outcome))
				log.Printf("restore original %s if trashed: %s", result.ID, outcome)
			}
			old := r.Header.Get("X-Replace-Asset-Id")
			// An edited render goes on top of a stack with the untouched original under it.
			// Skipped when Immich matched the render to the original itself (same bytes).
			if original := r.Header.Get("X-Stack-Original-Id"); original != "" && original != result.ID {
				outcome := stackEdit(r.Context(), client, immich, r.Header.Get("x-api-key"), original, old, result.ID)
				w.Header().Set(hStacked, headerSafe(outcome))
				log.Printf("stack %s on original %s (was %s): %s", result.ID, original, old, outcome)
			} else if old != "" && old != result.ID {
				// An edited photo replaces the asset uploaded before the edit. Skipped when Immich
				// matched the upload to that same asset (e.g. the edit was reverted).
				outcome := replace(r.Context(), client, immich, r.Header.Get("x-api-key"), old, result.ID)
				w.Header().Set(hReplaced, headerSafe(outcome))
				log.Printf("replace %s with %s: %s", old, result.ID, outcome)
			}
		} else {
			w.Header().Set(hError, headerSafe(fmt.Sprint(result.Message)))
		}
		log.Printf("upload %q (%s): immich %d %s %s in %s", filename, contentType, resp.StatusCode, result.Status, result.ID, time.Since(start).Round(time.Millisecond))
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(resp.StatusCode)
		w.Write(respBody)
	}
}

// replace copies albums, shared links, stack and sidecar from the old asset to the new one,
// then moves the old one to Immich's trash. Favorite is not copied: the phone's value was uploaded.
// If the old asset is already gone, there is nothing to do.
func replace(ctx context.Context, client *http.Client, immich, apiKey, oldID, newID string) string {
	copyBody := map[string]any{"sourceId": oldID, "targetId": newID, "favorite": false}
	code, msg, err := immichJSON(ctx, client, http.MethodPut, immich+"/api/assets/copy", apiKey, copyBody)
	switch {
	case err != nil:
		return "copy failed: " + err.Error()
	case code == http.StatusBadRequest && strings.Contains(msg, "must exist"):
		return "ok (old asset already gone)"
	case code/100 != 2:
		return fmt.Sprintf("copy HTTP %d %s", code, msg)
	}
	code, msg, err = immichJSON(ctx, client, http.MethodDelete, immich+"/api/assets", apiKey, map[string]any{"ids": []string{oldID}})
	switch {
	case err != nil:
		return "trash failed: " + err.Error()
	case code/100 != 2:
		return fmt.Sprintf("trash HTTP %d %s", code, msg)
	}
	return "ok"
}

// stackEdit puts a new render (newID) on top of a stack with the original under it. oldID is what
// stood for the photo before: a previous render (its albums, shared links and sidecar are copied,
// its stack removed, then it is trashed) or the original itself (albums copied, nothing trashed).
// When Immich matched the upload to oldID (the render was already there), only the stack is made.
func stackEdit(ctx context.Context, client *http.Client, immich, apiKey, originalID, oldID, newID string) string {
	if oldID != "" && oldID != newID {
		copyBody := map[string]any{"sourceId": oldID, "targetId": newID, "stack": false, "favorite": false}
		code, msg, err := immichJSON(ctx, client, http.MethodPut, immich+"/api/assets/copy", apiKey, copyBody)
		switch {
		case err != nil:
			return "copy failed: " + err.Error()
		case code/100 != 2 && !(code == http.StatusBadRequest && strings.Contains(msg, "must exist")):
			return fmt.Sprintf("copy HTTP %d %s", code, msg)
		}
		if oldID != originalID {
			// The previous render's stack; otherwise it would stay behind as a stack of one.
			ids, err := stackIDs(ctx, client, immich, apiKey, oldID)
			if err != nil {
				return "stack lookup failed: " + err.Error()
			}
			for _, id := range ids {
				code, msg, err := immichJSON(ctx, client, http.MethodDelete, immich+"/api/stacks/"+url.PathEscape(id), apiKey, nil)
				if err != nil || code/100 != 2 {
					return fmt.Sprintf("unstack HTTP %d %s %v", code, msg, err)
				}
			}
		}
	}
	// The first ID is the one shown. A stack already topped by newID is merged into this one.
	code, msg, err := immichJSON(ctx, client, http.MethodPost, immich+"/api/stacks", apiKey, map[string]any{"assetIds": []string{newID, originalID}})
	switch {
	case err != nil:
		return "stack failed: " + err.Error()
	case code/100 != 2:
		return fmt.Sprintf("stack HTTP %d %s", code, msg)
	}
	if oldID != "" && oldID != newID && oldID != originalID {
		code, msg, err := immichJSON(ctx, client, http.MethodDelete, immich+"/api/assets", apiKey, map[string]any{"ids": []string{oldID}})
		switch {
		case err != nil:
			return "trash failed: " + err.Error()
		case code/100 != 2:
			return fmt.Sprintf("trash HTTP %d %s", code, msg)
		}
	}
	return "ok"
}

// stackIDs returns the IDs of the stacks whose top asset is primaryID.
func stackIDs(ctx context.Context, client *http.Client, immich, apiKey, primaryID string) ([]string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, immich+"/api/stacks?primaryAssetId="+url.QueryEscape(primaryID), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("x-api-key", apiKey)
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	var stacks []struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&stacks); err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(stacks))
	for _, s := range stacks {
		ids = append(ids, s.ID)
	}
	return ids, nil
}

// immichJSON sends a JSON request (no body when body is nil) and returns the status and
// Immich's error message, if any.
func immichJSON(ctx context.Context, client *http.Client, method, url, apiKey string, body any) (int, string, error) {
	var reader io.Reader
	if body != nil {
		data, _ := json.Marshal(body)
		reader = bytes.NewReader(data)
	}
	req, err := http.NewRequestWithContext(ctx, method, url, reader)
	if err != nil {
		return 0, "", err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("x-api-key", apiKey)
	resp, err := client.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	var result struct {
		Message any `json:"message"`
	}
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	_ = json.Unmarshal(respBody, &result)
	if result.Message == nil {
		return resp.StatusCode, "", nil
	}
	return resp.StatusCode, fmt.Sprint(result.Message), nil
}

// uploadFields maps our request headers to Immich's AssetMediaCreateDto form fields.
func uploadFields(h http.Header) (fields [][2]string, filename, contentType string) {
	now := time.Now().UTC().Format(time.RFC3339)
	created := firstNonEmpty(h.Get("X-File-Created-At"), now)
	fields = [][2]string{
		{"fileCreatedAt", created},
		{"fileModifiedAt", firstNonEmpty(h.Get("X-File-Modified-At"), created)},
		{"isFavorite", firstNonEmpty(h.Get("X-Is-Favorite"), "false")},
	}
	if v := h.Get("X-Duration-Ms"); v != "" {
		fields = append(fields, [2]string{"duration", v})
	}
	if v := h.Get("X-Live-Photo-Video-Id"); v != "" {
		fields = append(fields, [2]string{"livePhotoVideoId", v})
	}
	filename, err := url.PathUnescape(h.Get("X-Filename"))
	if err != nil || filename == "" {
		filename = "upload"
	}
	fields = append(fields, [2]string{"filename", filename})
	contentType = firstNonEmpty(h.Get("X-Content-Type"), "application/octet-stream")
	return fields, filename, contentType
}

func writeMultipart(mp *multipart.Writer, fields [][2]string, filename, contentType string, data io.Reader) error {
	for _, f := range fields {
		if err := mp.WriteField(f[0], f[1]); err != nil {
			return err
		}
	}
	part := textproto.MIMEHeader{}
	part.Set("Content-Disposition", fmt.Sprintf(`form-data; name="assetData"; filename=%q`, filename))
	part.Set("Content-Type", contentType)
	w, err := mp.CreatePart(part)
	if err != nil {
		return err
	}
	if _, err := io.Copy(w, data); err != nil {
		return err
	}
	return mp.Close()
}

func fail(w http.ResponseWriter, code int, msg string) {
	w.Header().Set(hStatus, fmt.Sprint(code))
	w.Header().Set(hError, headerSafe(msg))
	w.WriteHeader(code)
}

func headerSafe(s string) string {
	s = strings.Map(func(r rune) rune {
		if r < 0x20 || r > 0x7e {
			return ' '
		}
		return r
	}, s)
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// logHandler takes the app's debug log (Settings > Advanced, off by default) and writes each line
// to this container's log, so a developer can follow a test with `docker logs`. Only callers with an
// API key Immich accepts are logged; keys are checked once an hour.
func logHandler(immich string, client *http.Client) http.HandlerFunc {
	var mu sync.Mutex
	known := map[string]struct {
		name  string
		until time.Time
	}{}
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		key := r.Header.Get("x-api-key")
		mu.Lock()
		entry, ok := known[key]
		mu.Unlock()
		if !ok || time.Now().After(entry.until) {
			req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, immich+"/api/users/me", nil)
			if err != nil {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			req.Header.Set("x-api-key", key)
			resp, err := client.Do(req)
			if err != nil {
				w.WriteHeader(http.StatusBadGateway)
				return
			}
			var me struct {
				ID string `json:"id"`
			}
			_ = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&me)
			resp.Body.Close()
			if resp.StatusCode != http.StatusOK || me.ID == "" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			entry.name, entry.until = me.ID[:8], time.Now().Add(time.Hour)
			mu.Lock()
			known[key] = entry
			mu.Unlock()
		}
		lines := bufio.NewScanner(io.LimitReader(r.Body, 512<<10))
		lines.Buffer(make([]byte, 64<<10), 64<<10)
		for lines.Scan() {
			if text := strings.TrimSpace(lines.Text()); text != "" {
				log.Printf("phone %s: %s", entry.name, text)
			}
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

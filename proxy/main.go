// immich-backup-proxy turns PhotoKit background uploads into Immich uploads.
//
// PhotoKit sends the photo as the raw request body, with our metadata in headers.
// Immich only accepts multipart/form-data on POST /api/assets, so this streams the
// body into a multipart request (never holding the file in memory) and reports the
// result back in response headers, the only part of the response PhotoKit keeps.
package main

import (
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
	"time"
)

func main() {
	listen := envOr("LISTEN_ADDR", "127.0.0.1:2284")
	immich := strings.TrimRight(envOr("IMMICH_URL", "http://127.0.0.1:2283"), "/")

	mux := http.NewServeMux()
	mux.HandleFunc("/api/assets/background", uploadHandler(immich, http.DefaultClient))
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
	hAssetID = "X-Immich-Asset-Id" // Immich asset ID, set on success (created or duplicate)
	hStatus  = "X-Immich-Status"   // Immich HTTP status code
	hResult  = "X-Immich-Result"   // Immich's "created" / "duplicate" / "replaced"
	hError   = "X-Immich-Error"    // short error text on failure
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
		} else {
			w.Header().Set(hError, headerSafe(fmt.Sprint(result.Message)))
		}
		log.Printf("upload %q (%s): immich %d %s %s in %s", filename, contentType, resp.StatusCode, result.Status, result.ID, time.Since(start).Round(time.Millisecond))
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(resp.StatusCode)
		w.Write(respBody)
	}
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

package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"strconv"
	"strings"
	"time"
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/echo", handleEcho)
	mux.HandleFunc("/hash", handleHash)
	mux.HandleFunc("/payload/", handlePayload)
	mux.HandleFunc("/health", handleHealth)

	addr := ":8080"
	log.Printf("validation-server listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

// handleEcho returns JSON with all request metadata and echoes X-Request-ID.
func handleEcho(w http.ResponseWriter, r *http.Request) {
	requestID := r.Header.Get("X-Request-ID")

	headers := make(map[string]string)
	for name, values := range r.Header {
		headers[name] = strings.Join(values, ", ")
	}

	resp := map[string]interface{}{
		"request_id": requestID,
		"method":     r.Method,
		"path":       r.URL.Path,
		"host":       r.Host,
		"headers":    headers,
		"remote_addr": r.RemoteAddr,
		"timestamp":  time.Now().UTC().Format(time.RFC3339),
	}

	if requestID != "" {
		w.Header().Set("X-Request-ID", requestID)
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

// handleHash reads the POST body, computes SHA-256, and returns the hash and size.
func handleHash(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}

	h := sha256.New()
	size, err := io.Copy(h, r.Body)
	if err != nil {
		http.Error(w, "read error: "+err.Error(), http.StatusInternalServerError)
		return
	}

	requestID := r.Header.Get("X-Request-ID")
	resp := map[string]interface{}{
		"sha256":     fmt.Sprintf("%x", h.Sum(nil)),
		"size":       size,
		"request_id": requestID,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

// handlePayload returns deterministic bytes of the requested size.
// The same size always produces the same content (seeded PRNG), so clients
// can pre-compute the expected SHA-256.
// Usage: GET /payload/12582912  (12 MB)
func handlePayload(w http.ResponseWriter, r *http.Request) {
	sizeStr := strings.TrimPrefix(r.URL.Path, "/payload/")
	size, err := strconv.ParseInt(sizeStr, 10, 64)
	if err != nil || size <= 0 || size > 100*1024*1024 {
		http.Error(w, "invalid size (1 to 104857600)", http.StatusBadRequest)
		return
	}

	// Deterministic: same seed for same size → same bytes → same hash.
	rng := rand.New(rand.NewSource(size))

	// Pre-compute hash by generating once into a hasher.
	h := sha256.New()
	buf := make([]byte, 32*1024)
	remaining := size
	for remaining > 0 {
		n := int64(len(buf))
		if n > remaining {
			n = remaining
		}
		for i := int64(0); i < n; i++ {
			buf[i] = byte(rng.Intn(256))
		}
		h.Write(buf[:n])
		remaining -= n
	}
	hash := fmt.Sprintf("%x", h.Sum(nil))

	// Reset RNG and stream the same bytes to the client.
	rng = rand.New(rand.NewSource(size))
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	w.Header().Set("X-Payload-SHA256", hash)

	remaining = size
	for remaining > 0 {
		n := int64(len(buf))
		if n > remaining {
			n = remaining
		}
		for i := int64(0); i < n; i++ {
			buf[i] = byte(rng.Intn(256))
		}
		w.Write(buf[:n])
		remaining -= n
	}
}

// handleHealth returns a simple health check response.
func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"status":"ok"}`))
}

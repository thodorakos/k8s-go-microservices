package main

import (
	"encoding/json"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var httpReqs = promauto.NewCounter(prometheus.CounterOpts{
	Name: "helloapi_http_requests_total", Help: "HTTP requests handled by hello-api",
})

func count(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) { httpReqs.Inc(); next(w, r) }
}

type upstreamReply struct {
	Service string `json:"service"`
	Message string `json:"message"`
	Version string `json:"version"`
	Host    string `json:"host"`
}

type response struct {
	Service  string `json:"service"`
	Route    string `json:"route"`
	Message  string `json:"message"`
	Version  string `json:"version"`
	Upstream string `json:"upstream_host"`
}

func send(w http.ResponseWriter, r response) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(r)
}

func env(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func main() {
	port := env("PORT", "8080")
	v1URL := env("GREETING_API_URL", "http://greeting-api:8080")
	v2URL := env("GREETING_API_V2_URL", "http://greeting-api-v2:8080")
	weight, _ := strconv.Atoi(os.Getenv("CANARY_WEIGHT"))

	client := &http.Client{Timeout: 3 * time.Second}

	http.Handle("/metrics", promhttp.Handler())
	http.HandleFunc("/hello", count(func(w http.ResponseWriter, _ *http.Request) {
		url := v1URL
		route := "v1"
		if weight > 0 && rand.Intn(100) < weight {
			url = v2URL
			route = "v2"
		}
		resp, err := client.Get(url + "/ping")
		if err != nil {
			w.WriteHeader(http.StatusBadGateway)
			send(w, response{Service: "hello-api", Route: route, Message: "greeting-api unreachable", Version: "error"})
			return
		}
		defer resp.Body.Close()
		var u upstreamReply
		if err := json.NewDecoder(resp.Body).Decode(&u); err != nil {
			w.WriteHeader(http.StatusBadGateway)
			send(w, response{Service: "hello-api", Route: route, Message: "greeting-api returned bad payload", Version: "error"})
			return
		}
		send(w, response{Service: "hello-api", Route: route, Message: u.Message, Version: u.Version, Upstream: u.Host})
	}))
	http.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	log.Printf("hello-api listening on :%s canary=%d%%", port, weight)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

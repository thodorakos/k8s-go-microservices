package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

type reply struct {
	Service string `json:"service"`
	Message string `json:"message"`
	Version string `json:"version"`
	Host    string `json:"host"`
}

func send(w http.ResponseWriter, r reply) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(r)
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	version := os.Getenv("SERVICE_VERSION")
	if version == "" {
		version = "v1"
	}
	host, _ := os.Hostname()

	http.HandleFunc("/ping", func(w http.ResponseWriter, _ *http.Request) {
		send(w, reply{Service: "greeting-api", Message: "pong", Version: version, Host: host})
	})
	http.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	log.Printf("greeting-api %s listening on :%s", version, port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

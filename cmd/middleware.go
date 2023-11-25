package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
)

func ClientMiddleware(client HandlerClient, projectInfo *ProjectInfo, handler handlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		handler(w, r, client, projectInfo)
	}
}

type AttachmentRequest struct {
	FilePath string `json:"file_path"`
	FileName string `json:"file_name"`
}

type contextKey string

var (
	fileReaderKey = contextKey("fileReader")
)

/* FileMiddleware reads a file and passes the contens to the next path */
func FileMiddleware(next http.Handler) http.HandlerFunc {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var attachmentRequest AttachmentRequest

		body, err := io.ReadAll(r.Body)
		if err != nil {
			HandleError(w, err, "Could not read request body", http.StatusBadRequest)
			return
		}

		defer r.Body.Close()

		err = json.Unmarshal(body, &attachmentRequest)
		if err != nil {
			HandleError(w, err, "Could not unmarshal JSON", http.StatusBadRequest)
			return
		}

		if err != nil {
			HandleError(w, err, fmt.Sprintf("Could not read %s", attachmentRequest.FilePath), http.StatusBadRequest)
			return
		}

		file, err := os.Open(attachmentRequest.FilePath)
		if err != nil {
			HandleError(w, err, fmt.Sprintf("Could not read %s", attachmentRequest.FilePath), http.StatusBadRequest)
			return
		}

		data, err := io.ReadAll(file)
		if err != nil {
			HandleError(w, err, fmt.Sprintf("Error reading file %s", attachmentRequest.FilePath), http.StatusBadRequest)
		}

		defer file.Close()

		reader := bytes.NewReader(data)
		ctx := context.WithValue(context.Background(), fileReaderKey, reader)
		requestWithReader := r.WithContext(ctx)
		requestWithReader.Body = io.NopCloser(bytes.NewReader(body))

		next.ServeHTTP(w, requestWithReader)
	})
}
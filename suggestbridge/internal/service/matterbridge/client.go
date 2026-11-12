package matterbridge

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"suggestbridge/internal/errors"
	"suggestbridge/internal/model"
	"time"
)

type Client interface {
	Post(ctx context.Context, username, text string) error
	Listen(ctx context.Context, messages chan<- model.ChatMessage) error
}

type client struct {
	apiURL     string
	apiToken   string
	gateway    string
	httpClient *http.Client
	streamHTTP *http.Client
}

func NewClient(apiURL, apiToken, gateway string, httpClient, streamHTTP *http.Client) Client {
	return &client{
		apiURL:     apiURL,
		apiToken:   apiToken,
		gateway:    gateway,
		httpClient: httpClient,
		streamHTTP: streamHTTP,
	}
}

func (client *client) Post(ctx context.Context, username, text string) error {
	body, err := json.Marshal(map[string]string{"text": text, "username": username, "gateway": client.gateway})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, client.apiURL+"/api/message", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+client.apiToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return errors.ErrRequestFailed
	}
	return nil
}

func (client *client) Listen(ctx context.Context, messages chan<- model.ChatMessage) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	idle := time.AfterFunc(10*time.Minute, cancel)
	defer idle.Stop()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, client.apiURL+"/api/stream", nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+client.apiToken)

	resp, err := client.streamHTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return errors.ErrRequestFailed
	}

	decoder := json.NewDecoder(resp.Body)
	for {
		var message model.ChatMessage
		if err := decoder.Decode(&message); err != nil {
			return err
		}
		idle.Reset(10 * time.Minute)
		if message.Gateway == client.gateway && message.Event == "" && message.Protocol != "api" {
			messages <- message
		}
	}
}

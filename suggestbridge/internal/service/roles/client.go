package roles

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"suggestbridge/internal/errors"
	"suggestbridge/internal/model"
)

type Client interface {
	Get(ctx context.Context) (*model.Roles, error)
}

type client struct {
	rolesURL   string
	secret     string
	httpClient *http.Client
}

func NewClient(rolesURL, secret string, httpClient *http.Client) Client {
	return &client{
		rolesURL:   rolesURL,
		secret:     secret,
		httpClient: httpClient,
	}
}

func (client *client) Get(ctx context.Context) (*model.Roles, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, client.rolesURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Chat-Secret", client.secret)

	resp, err := client.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, errors.ErrRequestFailed
	}

	var roles model.Roles
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&roles); err != nil {
		return nil, err
	}
	return &roles, nil
}

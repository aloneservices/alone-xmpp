package errors

import "errors"

var (
	ErrSuggestionNotFound = errors.New("suggestion not found")
	ErrInvalidWebhookURL  = errors.New("invalid webhook url")
	ErrRequestFailed      = errors.New("request failed")
)

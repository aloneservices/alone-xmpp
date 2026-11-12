package forum

import (
	"context"
	goerrors "errors"
	"net/url"
	"regexp"
	"suggestbridge/internal/errors"

	"github.com/bwmarrin/discordgo"
)

type Client interface {
	CreatePost(ctx context.Context, title, username, text string) (string, error)
	Reply(ctx context.Context, threadID, username, text string) error
	SetLocked(ctx context.Context, threadID string, locked bool) error
	Rename(ctx context.Context, threadID, name string) error
}

type client struct {
	session      *discordgo.Session
	webhookID    string
	webhookToken string
}

func NewClient(session *discordgo.Session, webhookURL string) (Client, error) {
	parts := regexp.MustCompile(`/webhooks/(\d+)/([\w-]+)`).FindStringSubmatch(webhookURL)
	if parts == nil {
		return nil, errors.ErrInvalidWebhookURL
	}
	return &client{
		session:      session,
		webhookID:    parts[1],
		webhookToken: parts[2],
	}, nil
}

func noPings() *discordgo.MessageAllowedMentions {
	return &discordgo.MessageAllowedMentions{Parse: []discordgo.AllowedMentionType{}}
}

func clip(text string, limit int) string {
	if runes := []rune(text); len(runes) > limit {
		return string(runes[:limit-1]) + "…"
	}
	return text
}

func withoutURL(err error) error {
	var urlErr *url.Error
	if goerrors.As(err, &urlErr) {
		return urlErr.Err
	}
	return err
}

func (client *client) CreatePost(ctx context.Context, title, username, text string) (string, error) {
	message, err := client.session.WebhookExecute(client.webhookID, client.webhookToken, true, &discordgo.WebhookParams{
		Content:         clip(text, 2000),
		Username:        clip(username, 80),
		ThreadName:      clip(title, 100),
		AllowedMentions: noPings(),
	}, discordgo.WithContext(ctx))
	if err != nil {
		return "", withoutURL(err)
	}
	return message.ChannelID, nil
}

func (client *client) Reply(ctx context.Context, threadID, username, text string) error {
	_, err := client.session.WebhookThreadExecute(client.webhookID, client.webhookToken, false, threadID, &discordgo.WebhookParams{
		Content:         clip(text, 2000),
		Username:        clip(username, 80),
		AllowedMentions: noPings(),
	}, discordgo.WithContext(ctx))
	return withoutURL(err)
}

func (client *client) SetLocked(ctx context.Context, threadID string, locked bool) error {
	_, err := client.session.ChannelEditComplex(threadID, &discordgo.ChannelEdit{Archived: &locked, Locked: &locked}, discordgo.WithContext(ctx))
	return withoutURL(err)
}

func (client *client) Rename(ctx context.Context, threadID, name string) error {
	_, err := client.session.ChannelEdit(threadID, &discordgo.ChannelEdit{Name: clip(name, 100)}, discordgo.WithContext(ctx))
	return withoutURL(err)
}

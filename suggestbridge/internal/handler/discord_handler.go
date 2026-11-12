package handler

import (
	"strings"
	"suggestbridge/internal/model"
	"suggestbridge/internal/service"

	"github.com/bwmarrin/discordgo"
)

func forumThread(session *discordgo.Session, channelID, forumID string) *discordgo.Channel {
	channel, err := session.State.Channel(channelID)
	if err != nil {
		if channel, err = session.Channel(channelID); err != nil {
			return nil
		}
	}
	if !channel.IsThread() || channel.ParentID != forumID {
		return nil
	}
	return channel
}

func MessageCreate(suggestionService service.SuggestionService, forumID string) func(*discordgo.Session, *discordgo.MessageCreate) {
	return func(session *discordgo.Session, event *discordgo.MessageCreate) {
		if event.Author == nil || event.Author.Bot || event.WebhookID != "" {
			return
		}
		thread := forumThread(session, event.ChannelID, forumID)
		if thread == nil {
			return
		}

		name := event.Author.GlobalName
		if name == "" {
			name = event.Author.Username
		}
		text := event.Content
		for _, attachment := range event.Attachments {
			text = strings.TrimSpace(text + "\n" + attachment.URL)
		}

		suggestionService.DiscordMessage(model.DiscordMessage{
			ThreadID:   thread.ID,
			ThreadName: thread.Name,
			AuthorID:   event.Author.ID,
			AuthorName: name,
			Text:       text,
		})
	}
}

func ThreadUpdate(suggestionService service.SuggestionService, forumID string) func(*discordgo.Session, *discordgo.ThreadUpdate) {
	return func(session *discordgo.Session, event *discordgo.ThreadUpdate) {
		if event.Channel == nil || event.ParentID != forumID || event.ThreadMetadata == nil {
			return
		}
		suggestionService.ThreadLock(model.ThreadLock{
			ThreadID: event.ID,
			Locked:   event.ThreadMetadata.Locked,
		})
	}
}

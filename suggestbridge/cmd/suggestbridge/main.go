package main

import (
	"context"
	"log"
	"net/http"
	"suggestbridge/internal/config"
	"suggestbridge/internal/handler"
	"suggestbridge/internal/model"
	"suggestbridge/internal/repository"
	"suggestbridge/internal/service"
	"suggestbridge/internal/service/forum"
	"suggestbridge/internal/service/matterbridge"
	"suggestbridge/internal/service/roles"
	"time"

	"github.com/bwmarrin/discordgo"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

func main() {
	config.LoadEnv()
	ctx := context.Background() // TODO pass in context from params

	db, err := gorm.Open(sqlite.Open(config.Config.DBPath), &gorm.Config{
		TranslateError: true,
		Logger: logger.New(log.Default(), logger.Config{
			SlowThreshold:             time.Second,
			LogLevel:                  logger.Warn,
			IgnoreRecordNotFoundError: true,
		}),
	})
	if err != nil {
		log.Fatal(err)
	}
	if err := db.AutoMigrate(&model.Suggestion{}); err != nil {
		log.Fatal(err)
	}

	suggestionRepository := repository.NewSuggestionRepository(db)

	session, err := discordgo.New("Bot " + config.Config.DiscordToken)
	if err != nil {
		log.Fatal(err)
	}
	session.Identify.Intents = discordgo.IntentsGuilds | discordgo.IntentsGuildMessages | discordgo.IntentMessageContent
	session.SyncEvents = true

	forumClient, err := forum.NewClient(session, config.Config.WebhookURL)
	if err != nil {
		log.Fatal(err)
	}
	httpClient := &http.Client{Timeout: 20 * time.Second}
	matterbridgeClient := matterbridge.NewClient(config.Config.APIURL, config.Config.APIToken, config.Config.Gateway, httpClient, &http.Client{})
	rolesClient := roles.NewClient(config.Config.RolesURL, config.Config.ChatSecret, httpClient)

	suggestionService := service.NewSuggestionService(ctx, suggestionRepository, forumClient, matterbridgeClient, rolesClient, config.Config.SystemName)

	session.AddHandler(handler.MessageCreate(suggestionService, config.Config.ForumID))
	session.AddHandler(handler.ThreadUpdate(suggestionService, config.Config.ForumID))
	if err := session.Open(); err != nil {
		log.Fatal(err)
	}
	defer session.Close()

	select {}
}

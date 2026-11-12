package service

import (
	"context"
	goerrors "errors"
	"fmt"
	"log"
	"regexp"
	"strconv"
	"strings"
	"suggestbridge/internal/errors"
	"suggestbridge/internal/model"
	"suggestbridge/internal/repository"
	"suggestbridge/internal/service/forum"
	"suggestbridge/internal/service/matterbridge"
	"suggestbridge/internal/service/roles"
	"time"
)

type SuggestionService interface {
	DiscordMessage(message model.DiscordMessage)
	ThreadLock(lock model.ThreadLock)
}

type suggestionService struct {
	ctx                  context.Context
	suggestionRepository repository.SuggestionRepository
	forumClient          forum.Client
	matterbridgeClient   matterbridge.Client
	rolesClient          roles.Client
	systemName           string
	roles                *model.Roles
	chatMessages         chan model.ChatMessage
	discordMessages      chan model.DiscordMessage
	threadLocks          chan model.ThreadLock
	commandRe            *regexp.Regexp
	replyRe              *regexp.Regexp
	quoteRe              *regexp.Regexp
	plainRe              *regexp.Regexp
	numberRe             *regexp.Regexp
}

func NewSuggestionService(ctx context.Context, suggestionRepository repository.SuggestionRepository, forumClient forum.Client,
	matterbridgeClient matterbridge.Client, rolesClient roles.Client, systemName string) SuggestionService {
	service := &suggestionService{
		ctx:                  ctx,
		suggestionRepository: suggestionRepository,
		forumClient:          forumClient,
		matterbridgeClient:   matterbridgeClient,
		rolesClient:          rolesClient,
		systemName:           systemName,
		roles:                &model.Roles{},
		chatMessages:         make(chan model.ChatMessage, 256),
		discordMessages:      make(chan model.DiscordMessage, 256),
		threadLocks:          make(chan model.ThreadLock, 64),
		commandRe:            regexp.MustCompile(`^#(\d+)\s+(lock|unlock)$`),
		replyRe:              regexp.MustCompile(`^#(\d+)\s+([\s\S]+)$`),
		quoteRe:              regexp.MustCompile(`^(?:> ?|↪ )[^\n]*?#(\d+)[^\n]*\n([\s\S]+)$`),
		plainRe:              regexp.MustCompile(`^(?:> ?|↪ )(?:[^:\n]{1,80}: )?([^\n]*)\n([\s\S]+)$`),
		numberRe:             regexp.MustCompile(`^#\d+ · `),
	}
	go service.run()
	go service.listener()
	return service
}

func (service *suggestionService) DiscordMessage(message model.DiscordMessage) {
	select {
	case service.discordMessages <- message:
	default:
		log.Println("suggestions queue full, dropped a Discord message")
	}
}

func (service *suggestionService) ThreadLock(lock model.ThreadLock) {
	select {
	case service.threadLocks <- lock:
	default:
		log.Println("suggestions queue full, dropped a thread update")
	}
}

// TODO maybe make exitable
func (service *suggestionService) run() {
	service.refreshRoles()
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()

	for {
		var err error
		select {
		case message := <-service.chatMessages:
			err = service.handleChat(message)
		case message := <-service.discordMessages:
			err = service.handleDiscord(message)
		case lock := <-service.threadLocks:
			err = service.handleThreadLock(lock)
		case <-ticker.C:
			service.refreshRoles()
		}
		if err != nil {
			log.Println(err)
		}
	}
}

// TODO maybe make exitable
func (service *suggestionService) listener() {
	for {
		if err := service.matterbridgeClient.Listen(service.ctx, service.chatMessages); err != nil {
			log.Println(err)
		}
		time.Sleep(5 * time.Second)
	}
}

func (service *suggestionService) refreshRoles() {
	roles, err := service.rolesClient.Get(service.ctx)
	if err != nil {
		log.Println(err)
		return
	}
	service.roles = roles
}

func (service *suggestionService) isStaff(protocol, username string) bool {
	if protocol != "xmpp" && protocol != "irc" {
		return false
	}
	for _, list := range [][]string{service.roles.Admins, service.roles.Moderators} {
		for _, staff := range list {
			if strings.EqualFold(staff, username) {
				return true
			}
		}
	}
	return false
}

func (service *suggestionService) say(text string) error {
	return service.matterbridgeClient.Post(service.ctx, service.systemName, text)
}

func title(text string) string {
	line := strings.TrimSpace(strings.SplitN(text, "\n", 2)[0])
	if runes := []rune(line); len(runes) > 80 {
		line = string(runes[:80]) + "…"
	}
	if line == "" {
		return "Suggestion"
	}
	return line
}

func (service *suggestionService) handleChat(message model.ChatMessage) error {
	text := strings.TrimSpace(message.Text)
	if text == "" {
		return nil
	}
	label := message.Username + " · " + message.Protocol

	if match := service.commandRe.FindStringSubmatch(text); match != nil {
		number, err := strconv.Atoi(match[1])
		if err != nil {
			return service.say(fmt.Sprintf("There's no suggestion #%s", match[1]))
		}
		return service.lock(number, match[2] == "lock", message.Protocol, message.Username)
	}

	match := service.replyRe.FindStringSubmatch(text)
	if match == nil {
		match = service.quoteRe.FindStringSubmatch(text)
	}
	if match != nil {
		number, err := strconv.Atoi(match[1])
		if err != nil {
			return service.say(fmt.Sprintf("There's no suggestion #%s", match[1]))
		}
		return service.reply(number, label, strings.TrimSpace(match[2]))
	}

	if match := service.plainRe.FindStringSubmatch(text); match != nil {
		suggestion, err := service.suggestionRepository.GetByTitle(match[1])
		switch {
		case err == nil:
			return service.reply(suggestion.Number, label, strings.TrimSpace(match[2]))
		case goerrors.Is(err, errors.ErrSuggestionNotFound):
		default:
			return err
		}
	}
	return service.suggest(label, text)
}

func (service *suggestionService) sayFailed() {
	if err := service.say("Couldn't save that suggestion, try again in a minute"); err != nil {
		log.Println(err)
	}
}

func (service *suggestionService) suggest(label, text string) error {
	number, err := service.suggestionRepository.Reserve()
	if err != nil {
		service.sayFailed()
		return err
	}

	threadID, err := service.forumClient.CreatePost(service.ctx, fmt.Sprintf("#%d · %s", number, title(text)), label, text)
	if err != nil {
		service.sayFailed()
		return err
	}

	if err := service.suggestionRepository.SetThread(number, threadID, title(text)); err != nil {
		service.sayFailed()
		return err
	}
	return service.say(fmt.Sprintf("💡 Saved as #%d, reply with #%d and your message", number, number))
}

func (service *suggestionService) reply(number int, label, text string) error {
	suggestion, err := service.suggestionRepository.GetByNumber(number)
	switch {
	case err == nil:
	case goerrors.Is(err, errors.ErrSuggestionNotFound):
		return service.say(fmt.Sprintf("There's no suggestion #%d", number))
	default:
		return err
	}

	if suggestion.Locked {
		return service.say(fmt.Sprintf("🔒 #%d is locked", number))
	}
	return service.forumClient.Reply(service.ctx, suggestion.ThreadID, label, text)
}

func (service *suggestionService) lock(number int, locked bool, protocol, who string) error {
	if !service.isStaff(protocol, who) {
		return service.say("Only staff can lock suggestions")
	}

	suggestion, err := service.suggestionRepository.GetByNumber(number)
	switch {
	case err == nil:
	case goerrors.Is(err, errors.ErrSuggestionNotFound):
		return service.say(fmt.Sprintf("There's no suggestion #%d", number))
	default:
		return err
	}

	if err := service.forumClient.SetLocked(service.ctx, suggestion.ThreadID, locked); err != nil {
		if sayErr := service.say(fmt.Sprintf("Couldn't change #%d on Discord", number)); sayErr != nil {
			log.Println(sayErr)
		}
		return err
	}
	if err := service.suggestionRepository.SetLocked(number, locked); err != nil {
		return err
	}

	if locked {
		return service.say(fmt.Sprintf("🔒 #%d locked by %s", number, who))
	}
	return service.say(fmt.Sprintf("🔓 #%d unlocked by %s", number, who))
}

func (service *suggestionService) handleDiscord(message model.DiscordMessage) error {
	name := service.roles.Discord[message.AuthorID]
	if name == "" {
		name = message.AuthorName
	}
	label := name + " · discord"

	suggestion, err := service.suggestionRepository.GetByThread(message.ThreadID)
	switch {
	case err == nil:
	case goerrors.Is(err, errors.ErrSuggestionNotFound):
		return service.adopt(message, label)
	default:
		return err
	}

	if suggestion.Locked || message.Text == "" {
		return nil
	}
	return service.matterbridgeClient.Post(service.ctx, fmt.Sprintf("↪ #%d %s", suggestion.Number, label), message.Text)
}

func (service *suggestionService) adopt(message model.DiscordMessage, label string) error {
	number, err := service.suggestionRepository.Reserve()
	if err != nil {
		return err
	}
	name := title(service.numberRe.ReplaceAllString(message.ThreadName, ""))
	if err := service.forumClient.Rename(service.ctx, message.ThreadID, fmt.Sprintf("#%d · %s", number, name)); err != nil {
		return err
	}

	if err := service.suggestionRepository.SetThread(number, message.ThreadID, name); err != nil {
		return err
	}
	return service.matterbridgeClient.Post(service.ctx, fmt.Sprintf("💡 #%d %s", number, label), strings.TrimSpace(name+"\n"+message.Text))
}

func (service *suggestionService) handleThreadLock(lock model.ThreadLock) error {
	suggestion, err := service.suggestionRepository.GetByThread(lock.ThreadID)
	switch {
	case err == nil:
	case goerrors.Is(err, errors.ErrSuggestionNotFound):
		return nil
	default:
		return err
	}
	if suggestion.Locked == lock.Locked {
		return nil
	}

	if err := service.suggestionRepository.SetLocked(suggestion.Number, lock.Locked); err != nil {
		return err
	}
	if lock.Locked {
		return service.say(fmt.Sprintf("🔒 #%d locked on Discord", suggestion.Number))
	}
	return service.say(fmt.Sprintf("🔓 #%d unlocked on Discord", suggestion.Number))
}

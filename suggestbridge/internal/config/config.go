package config

import (
	"log"

	"github.com/caarlos0/env/v9"
)

var Config struct {
	DiscordToken string `env:"SUGGEST_TOKEN,required"`
	ForumID      string `env:"SUGGEST_FORUM,required"`
	WebhookURL   string `env:"SUGGEST_HOOK,required"`
	APIURL       string `env:"SUGGEST_API,required"`
	APIToken     string `env:"SUGGEST_API_TOKEN,required"`
	RolesURL     string `env:"SUGGEST_ROLES,required"`
	ChatSecret   string `env:"CHAT_SECRET,required"`
	DBPath       string `env:"SUGGEST_DB" envDefault:"/var/lib/suggestbridge/suggestions.db"`
	Gateway      string `env:"SUGGEST_GATEWAY" envDefault:"suggestions"`
	SystemName   string `env:"SUGGEST_NAME" envDefault:"suggestions"`
}

func LoadEnv() {
	if err := env.Parse(&Config); err != nil {
		log.Fatal(err)
	}
}

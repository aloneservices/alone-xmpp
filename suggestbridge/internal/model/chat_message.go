package model

type ChatMessage struct {
	Text     string `json:"text"`
	Username string `json:"username"`
	Protocol string `json:"protocol"`
	Gateway  string `json:"gateway"`
	Event    string `json:"event"`
}

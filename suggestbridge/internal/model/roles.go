package model

type Roles struct {
	Admins     []string          `json:"admins"`
	Moderators []string          `json:"moderators"`
	Discord    map[string]string `json:"discord"`
}

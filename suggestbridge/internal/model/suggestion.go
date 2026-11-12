package model

type Suggestion struct {
	Number   int    `gorm:"primaryKey;autoIncrement" json:"number"`
	ThreadID string `gorm:"index" json:"threadID"`
	Title    string `json:"title"`
	Locked   bool   `gorm:"not null;default:false" json:"locked"`
}

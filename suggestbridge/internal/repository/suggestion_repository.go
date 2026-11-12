package repository

import "suggestbridge/internal/model"

type SuggestionRepository interface {
	Reserve() (int, error)
	SetThread(number int, threadID, title string) error
	GetByNumber(number int) (*model.Suggestion, error)
	GetByThread(threadID string) (*model.Suggestion, error)
	GetByTitle(title string) (*model.Suggestion, error)
	SetLocked(number int, locked bool) error
}

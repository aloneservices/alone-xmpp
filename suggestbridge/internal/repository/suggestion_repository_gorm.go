package repository

import (
	goerrors "errors"
	"strings"
	"suggestbridge/internal/errors"
	"suggestbridge/internal/model"

	"gorm.io/gorm"
)

type suggestionRepository struct {
	db *gorm.DB
}

func NewSuggestionRepository(db *gorm.DB) SuggestionRepository {
	return &suggestionRepository{
		db: db,
	}
}

func (repo *suggestionRepository) Reserve() (int, error) {
	suggestion := model.Suggestion{}
	if err := repo.db.Create(&suggestion).Error; err != nil {
		return 0, err
	}
	return suggestion.Number, nil
}

func (repo *suggestionRepository) SetThread(number int, threadID, title string) error {
	result := repo.db.
		Model(&model.Suggestion{}).
		Where("number = ?", number).
		Updates(&model.Suggestion{ThreadID: threadID, Title: title})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return errors.ErrSuggestionNotFound
	}
	return nil
}

func (repo *suggestionRepository) get(query *gorm.DB) (*model.Suggestion, error) {
	var suggestion model.Suggestion
	err := query.
		Where("thread_id <> ''").
		First(&suggestion).Error
	if goerrors.Is(err, gorm.ErrRecordNotFound) {
		return nil, errors.ErrSuggestionNotFound
	}
	if err != nil {
		return nil, err
	}
	return &suggestion, nil
}

func (repo *suggestionRepository) GetByNumber(number int) (*model.Suggestion, error) {
	return repo.get(repo.db.Where("number = ?", number))
}

func (repo *suggestionRepository) GetByThread(threadID string) (*model.Suggestion, error) {
	return repo.get(repo.db.Where("thread_id = ?", threadID))
}

func normalise(text string) string {
	return strings.TrimSuffix(strings.ToLower(strings.Join(strings.Fields(text), " ")), "…")
}

func (repo *suggestionRepository) GetByTitle(title string) (*model.Suggestion, error) {
	quote := normalise(title)
	if len(quote) < 8 {
		return nil, errors.ErrSuggestionNotFound
	}

	var suggestions []*model.Suggestion
	err := repo.db.
		Select("number", "thread_id", "title", "locked").
		Where("thread_id <> ''").
		Order("number DESC").
		Find(&suggestions).Error
	if err != nil {
		return nil, err
	}

	for _, suggestion := range suggestions {
		name := normalise(suggestion.Title)
		if len(name) >= 8 && (strings.HasPrefix(name, quote) || strings.HasPrefix(quote, name)) {
			return suggestion, nil
		}
	}
	return nil, errors.ErrSuggestionNotFound
}

func (repo *suggestionRepository) SetLocked(number int, locked bool) error {
	result := repo.db.
		Model(&model.Suggestion{}).
		Where("number = ?", number).
		Update("locked", locked)
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return errors.ErrSuggestionNotFound
	}
	return nil
}

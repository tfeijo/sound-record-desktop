package store

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/tfeijo/sound-record-desktop/backend/models"

	_ "modernc.org/sqlite"
)

// isDuplicateColumnErr checks if the error is a "duplicate column name" error
// from an ALTER TABLE ADD COLUMN that was already applied.
func isDuplicateColumnErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "duplicate column name")
}

// DefaultDBPath returns the default database path for macOS.
func DefaultDBPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "MeetNotes", "meetnotes.db")
}

// Store wraps a SQLite database connection and provides CRUD operations.
type Store struct {
	db *sql.DB
}

// NewStore opens (or creates) the SQLite database at dbPath, runs migrations, and returns a Store.
func NewStore(dbPath string) (*Store, error) {
	// Ensure parent directory exists.
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o755); err != nil {
		return nil, fmt.Errorf("create db directory: %w", err)
	}

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}

	// Enable WAL mode for better concurrent read performance.
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		db.Close()
		return nil, fmt.Errorf("set WAL mode: %w", err)
	}

	// Enable foreign keys.
	if _, err := db.Exec("PRAGMA foreign_keys=ON"); err != nil {
		db.Close()
		return nil, fmt.Errorf("enable foreign keys: %w", err)
	}

	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("run migrations: %w", err)
	}

	return s, nil
}

// Close closes the underlying database connection.
func (s *Store) Close() error {
	return s.db.Close()
}

// migrate runs CREATE TABLE IF NOT EXISTS statements for all tables.
func (s *Store) migrate() error {
	migrations := []string{
		`CREATE TABLE IF NOT EXISTS meetings (
			id              TEXT PRIMARY KEY,
			title           TEXT NOT NULL DEFAULT '',
			date            TEXT NOT NULL DEFAULT '',
			start_time      TEXT,
			end_time        TEXT,
			duration_seconds INTEGER NOT NULL DEFAULT 0,
			speaker_count   INTEGER NOT NULL DEFAULT 0,
			status          TEXT NOT NULL DEFAULT 'recording',
			audio_path      TEXT NOT NULL DEFAULT '',
			mic_path        TEXT NOT NULL DEFAULT '',
			system_path     TEXT NOT NULL DEFAULT '',
			transcript_json TEXT NOT NULL DEFAULT '',
			summary_json    TEXT NOT NULL DEFAULT '',
			obsidian_path   TEXT NOT NULL DEFAULT '',
			meet_url        TEXT NOT NULL DEFAULT '',
			error           TEXT NOT NULL DEFAULT '',
			created_at      TEXT NOT NULL DEFAULT (datetime('now')),
			updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
		)`,
		`CREATE TABLE IF NOT EXISTS speaker_profiles (
			id              TEXT PRIMARY KEY,
			name            TEXT NOT NULL DEFAULT '',
			embedding_path  TEXT NOT NULL DEFAULT '',
			created_at      TEXT NOT NULL DEFAULT (datetime('now'))
		)`,
		`CREATE TABLE IF NOT EXISTS settings (
			key   TEXT PRIMARY KEY,
			value TEXT NOT NULL DEFAULT ''
		)`,
		// Add mic_path and system_path columns if they don't exist (idempotent via IF NOT EXISTS workaround).
		`ALTER TABLE meetings ADD COLUMN mic_path TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE meetings ADD COLUMN system_path TEXT NOT NULL DEFAULT ''`,
	}

	for _, m := range migrations {
		if _, err := s.db.Exec(m); err != nil {
			// Ignore "duplicate column" errors from ALTER TABLE migrations
			// that have already been applied.
			if !isDuplicateColumnErr(err) {
				return fmt.Errorf("migration: %w", err)
			}
		}
	}
	return nil
}

// --- Meetings CRUD ---

// CreateMeeting inserts a new meeting into the database.
func (s *Store) CreateMeeting(m *models.Meeting) error {
	now := time.Now().UTC()
	m.CreatedAt = now
	m.UpdatedAt = now

	_, err := s.db.Exec(`
		INSERT INTO meetings (id, title, date, start_time, end_time, duration_seconds,
			speaker_count, status, audio_path, mic_path, system_path, transcript_json, summary_json,
			obsidian_path, meet_url, error, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		m.ID, m.Title, m.Date,
		formatTimePtr(m.StartTime), formatTimePtr(m.EndTime),
		m.DurationSeconds, m.SpeakerCount, string(m.Status),
		m.AudioPath, m.MicPath, m.SystemPath, m.TranscriptJSON, m.SummaryJSON,
		m.ObsidianPath, m.MeetURL, m.Error,
		m.CreatedAt.Format(time.RFC3339), m.UpdatedAt.Format(time.RFC3339),
	)
	return err
}

// GetMeeting returns a single meeting by ID, or sql.ErrNoRows if not found.
func (s *Store) GetMeeting(id string) (*models.Meeting, error) {
	row := s.db.QueryRow(`
		SELECT id, title, date, start_time, end_time, duration_seconds,
			speaker_count, status, audio_path, mic_path, system_path, transcript_json, summary_json,
			obsidian_path, meet_url, error, created_at, updated_at
		FROM meetings WHERE id = ?`, id)

	return scanMeeting(row)
}

// ListMeetings returns meetings ordered by creation time descending, with pagination.
func (s *Store) ListMeetings(limit, offset int) ([]models.Meeting, error) {
	rows, err := s.db.Query(`
		SELECT id, title, date, start_time, end_time, duration_seconds,
			speaker_count, status, audio_path, mic_path, system_path, transcript_json, summary_json,
			obsidian_path, meet_url, error, created_at, updated_at
		FROM meetings ORDER BY created_at DESC LIMIT ? OFFSET ?`, limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var meetings []models.Meeting
	for rows.Next() {
		m, err := scanMeetingRows(rows)
		if err != nil {
			return nil, err
		}
		meetings = append(meetings, *m)
	}
	return meetings, rows.Err()
}

// UpdateMeeting updates all mutable fields of a meeting.
func (s *Store) UpdateMeeting(m *models.Meeting) error {
	m.UpdatedAt = time.Now().UTC()

	result, err := s.db.Exec(`
		UPDATE meetings SET
			title = ?, date = ?, start_time = ?, end_time = ?,
			duration_seconds = ?, speaker_count = ?, status = ?,
			audio_path = ?, mic_path = ?, system_path = ?,
			transcript_json = ?, summary_json = ?,
			obsidian_path = ?, meet_url = ?, error = ?, updated_at = ?
		WHERE id = ?`,
		m.Title, m.Date,
		formatTimePtr(m.StartTime), formatTimePtr(m.EndTime),
		m.DurationSeconds, m.SpeakerCount, string(m.Status),
		m.AudioPath, m.MicPath, m.SystemPath,
		m.TranscriptJSON, m.SummaryJSON,
		m.ObsidianPath, m.MeetURL, m.Error,
		m.UpdatedAt.Format(time.RFC3339),
		m.ID,
	)
	if err != nil {
		return err
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// DeleteMeeting removes a meeting by ID.
func (s *Store) DeleteMeeting(id string) error {
	result, err := s.db.Exec("DELETE FROM meetings WHERE id = ?", id)
	if err != nil {
		return err
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// --- Settings ---

// GetSetting returns the value for a settings key, or empty string if not found.
func (s *Store) GetSetting(key string) (string, error) {
	var value string
	err := s.db.QueryRow("SELECT value FROM settings WHERE key = ?", key).Scan(&value)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return value, err
}

// SetSetting upserts a settings key-value pair.
func (s *Store) SetSetting(key, value string) error {
	_, err := s.db.Exec(`
		INSERT INTO settings (key, value) VALUES (?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
		key, value,
	)
	return err
}

// GetAllSettings returns all settings as a key-value map.
func (s *Store) GetAllSettings() (map[string]string, error) {
	rows, err := s.db.Query("SELECT key, value FROM settings")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	settings := map[string]string{}
	for rows.Next() {
		var key, value string
		if err := rows.Scan(&key, &value); err != nil {
			return nil, err
		}
		settings[key] = value
	}
	return settings, rows.Err()
}

// --- Speaker Profiles ---

// CreateSpeakerProfile inserts a new speaker profile.
func (s *Store) CreateSpeakerProfile(p *models.SpeakerProfile) error {
	p.CreatedAt = time.Now().UTC()
	_, err := s.db.Exec(`
		INSERT INTO speaker_profiles (id, name, embedding_path, created_at)
		VALUES (?, ?, ?, ?)`,
		p.ID, p.Name, p.EmbeddingPath, p.CreatedAt.Format(time.RFC3339),
	)
	return err
}

// GetSpeakerProfile returns a speaker profile by ID.
func (s *Store) GetSpeakerProfile(id string) (*models.SpeakerProfile, error) {
	var p models.SpeakerProfile
	var createdAt string
	err := s.db.QueryRow(`
		SELECT id, name, embedding_path, created_at
		FROM speaker_profiles WHERE id = ?`, id).Scan(
		&p.ID, &p.Name, &p.EmbeddingPath, &createdAt,
	)
	if err != nil {
		return nil, err
	}
	if t, err := time.Parse(time.RFC3339, createdAt); err == nil {
		p.CreatedAt = t
	}
	return &p, nil
}

// ListSpeakerProfiles returns all speaker profiles ordered by name.
func (s *Store) ListSpeakerProfiles() ([]models.SpeakerProfile, error) {
	rows, err := s.db.Query(`
		SELECT id, name, embedding_path, created_at
		FROM speaker_profiles ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var profiles []models.SpeakerProfile
	for rows.Next() {
		var p models.SpeakerProfile
		var createdAt string
		if err := rows.Scan(&p.ID, &p.Name, &p.EmbeddingPath, &createdAt); err != nil {
			return nil, err
		}
		if t, err := time.Parse(time.RFC3339, createdAt); err == nil {
			p.CreatedAt = t
		}
		profiles = append(profiles, p)
	}
	return profiles, rows.Err()
}

// UpdateSpeakerProfile updates the name and embedding path of a speaker profile.
func (s *Store) UpdateSpeakerProfile(p *models.SpeakerProfile) error {
	result, err := s.db.Exec(`
		UPDATE speaker_profiles SET name = ?, embedding_path = ? WHERE id = ?`,
		p.Name, p.EmbeddingPath, p.ID,
	)
	if err != nil {
		return err
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// DeleteSpeakerProfile removes a speaker profile by ID.
func (s *Store) DeleteSpeakerProfile(id string) error {
	result, err := s.db.Exec("DELETE FROM speaker_profiles WHERE id = ?", id)
	if err != nil {
		return err
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// --- Helpers ---

// scanner is an interface satisfied by both *sql.Row and *sql.Rows.
type scanner interface {
	Scan(dest ...interface{}) error
}

func scanMeetingFromScanner(s scanner) (*models.Meeting, error) {
	var m models.Meeting
	var startTime, endTime, createdAt, updatedAt sql.NullString
	var status string

	err := s.Scan(
		&m.ID, &m.Title, &m.Date, &startTime, &endTime,
		&m.DurationSeconds, &m.SpeakerCount, &status,
		&m.AudioPath, &m.MicPath, &m.SystemPath, &m.TranscriptJSON, &m.SummaryJSON,
		&m.ObsidianPath, &m.MeetURL, &m.Error,
		&createdAt, &updatedAt,
	)
	if err != nil {
		return nil, err
	}

	m.Status = models.MeetingStatus(status)
	m.StartTime = parseTimePtr(startTime)
	m.EndTime = parseTimePtr(endTime)
	if createdAt.Valid {
		if t, err := time.Parse(time.RFC3339, createdAt.String); err == nil {
			m.CreatedAt = t
		}
	}
	if updatedAt.Valid {
		if t, err := time.Parse(time.RFC3339, updatedAt.String); err == nil {
			m.UpdatedAt = t
		}
	}
	return &m, nil
}

func scanMeeting(row *sql.Row) (*models.Meeting, error) {
	return scanMeetingFromScanner(row)
}

func scanMeetingRows(rows *sql.Rows) (*models.Meeting, error) {
	return scanMeetingFromScanner(rows)
}

func formatTimePtr(t *time.Time) sql.NullString {
	if t == nil {
		return sql.NullString{}
	}
	return sql.NullString{String: t.Format(time.RFC3339), Valid: true}
}

func parseTimePtr(ns sql.NullString) *time.Time {
	if !ns.Valid || ns.String == "" {
		return nil
	}
	t, err := time.Parse(time.RFC3339, ns.String)
	if err != nil {
		return nil
	}
	return &t
}

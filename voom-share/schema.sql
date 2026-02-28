CREATE TABLE videos (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    share_code TEXT UNIQUE NOT NULL,
    title TEXT NOT NULL,
    duration REAL NOT NULL DEFAULT 0,
    width INTEGER NOT NULL DEFAULT 0,
    height INTEGER NOT NULL DEFAULT 0,
    has_webcam INTEGER NOT NULL DEFAULT 0,
    file_size INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    expires_at TEXT NOT NULL,
    upload_completed INTEGER NOT NULL DEFAULT 0,
    view_count INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_videos_share_code ON videos(share_code);
CREATE INDEX idx_videos_expires_at ON videos(expires_at);

CREATE TABLE transcript_segments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
    start_time REAL NOT NULL,
    end_time REAL NOT NULL,
    text TEXT NOT NULL
);
CREATE INDEX idx_transcript_video_id ON transcript_segments(video_id);

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS devices (
    device_token TEXT PRIMARY KEY,
    locale TEXT NOT NULL DEFAULT 'vi_VN',
    app_version TEXT NOT NULL,
    os_version TEXT NOT NULL,
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS topic_subscriptions (
    device_token TEXT NOT NULL,
    topic TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (device_token, topic),
    FOREIGN KEY (device_token) REFERENCES devices(device_token) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_devices_active ON devices(is_active);
CREATE INDEX IF NOT EXISTS idx_topic_subscriptions ON topic_subscriptions(topic);
CREATE INDEX IF NOT EXISTS idx_topic_subscriptions_token ON topic_subscriptions(device_token);

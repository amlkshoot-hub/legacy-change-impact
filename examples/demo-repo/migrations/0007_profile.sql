ALTER TABLE user_profile ADD COLUMN nick_name VARCHAR(64);
CREATE INDEX idx_user_profile_uid ON user_profile (uid);

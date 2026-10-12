-- The parts of Wispr Flow's flow.sqlite that bin/ferry-corrections reads.
-- Names and types match the real schema (checked with `.schema History`
-- and `.schema Dictionary` only); every other column is left out.
-- tests/test-corrections.sh builds a temp WAL-mode database from this.
CREATE TABLE `History` (`transcriptEntityId` VARCHAR(36) NOT NULL UNIQUE PRIMARY KEY, `asrText` TEXT, `formattedText` TEXT, `timestamp` DATETIME, `app` VARCHAR(255), `pastedText` TEXT);
CREATE TABLE IF NOT EXISTS "Dictionary" (`id` VARCHAR(36) NOT NULL PRIMARY KEY, `phrase` VARCHAR(255) NOT NULL, `replacement` VARCHAR(255), `isDeleted` TINYINT(1) NOT NULL DEFAULT 0);

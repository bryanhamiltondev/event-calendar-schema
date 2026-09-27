-- =====================================================================
-- event-calendar-schema/schema.sql

-- Representative excerpt of the MySQL schema behind The DJ Calendar's
-- event pipeline: artists, venues, events, and newsletter alert
-- subscribers. Column sets are representative, not the live schema;
-- the design decisions are the real thing and are documented inline.

-- Engine: InnoDB throughout - every write path here needs transactions
-- and foreign keys. Charset: utf8mb4, because artist and venue names
-- are user-facing international text.
-- =====================================================================

CREATE TABLE artists (
  id            INT UNSIGNED     NOT NULL AUTO_INCREMENT,
  slug          VARCHAR(120)     NOT NULL,
  name          VARCHAR(160)     NOT NULL,
  name_normalized VARCHAR(160)   NOT NULL,  -- casefolded + diacritic-stripped for search
  spotify_id    VARCHAR(40)      DEFAULT NULL,
  bandsintown_id VARCHAR(120)    DEFAULT NULL,
  image_url     VARCHAR(255)     DEFAULT NULL,
  is_active     TINYINT(1)       NOT NULL DEFAULT 1,
  created_at    DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_artists_slug (slug),
  UNIQUE KEY uq_artists_name_normalized (name_normalized),
  KEY idx_artists_spotify (spotify_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE venues (
  id            INT UNSIGNED     NOT NULL AUTO_INCREMENT,
  slug          VARCHAR(160)     NOT NULL,
  name          VARCHAR(200)     NOT NULL,
  city          VARCHAR(120)     NOT NULL,
  region        VARCHAR(80)      DEFAULT NULL,
  country       CHAR(2)          DEFAULT NULL,          -- ISO 3166-1 alpha-2
  lat           DECIMAL(9,6)     DEFAULT NULL,          -- geocoded; NULL = not yet resolved
  lng           DECIMAL(9,6)     DEFAULT NULL,
  geocode_source ENUM('manual','nominatim','feed') DEFAULT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_venues_natural (name, city, country),   -- natural-key dedupe at the DB level
  KEY idx_venues_geo (lat, lng)                          -- bounding-box prefilter for "near me"
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE events (
  id            BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  artist_id     INT UNSIGNED     NOT NULL,
  venue_id      INT UNSIGNED     DEFAULT NULL,          -- NULL until the venue resolves
  source        ENUM('bandsintown','ticketmaster','manual') NOT NULL,
  source_event_id VARCHAR(80)    DEFAULT NULL,          -- upstream's own ID, for idempotent re-ingest
  event_date    DATETIME         NOT NULL,              -- show start, normalized to UTC
  timezone      VARCHAR(64)      DEFAULT NULL,          -- IANA tz of the venue, e.g. America/New_York
  ticket_url    VARCHAR(500)     DEFAULT NULL,
  is_sold_out   TINYINT(1)       NOT NULL DEFAULT 0,
  is_active     TINYINT(1)       NOT NULL DEFAULT 1,    -- soft delete; ingestion never hard-deletes
  created_at    DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  -- The dedupe contract: one artist + one natural venue key + one start
  -- time = one row. Re-ingesting the same feed is idempotent: the UNIQUE
  -- key turns every replay into an UPDATE, never a duplicate.
  UNIQUE KEY uq_events_natural (artist_id, venue_id, event_date),
  KEY idx_events_source (source, source_event_id),
  KEY idx_events_upcoming (is_active, event_date),       -- the site's hottest query: next N shows
  KEY idx_events_artist_date (artist_id, event_date),
  CONSTRAINT fk_events_artist FOREIGN KEY (artist_id) REFERENCES artists (id),
  CONSTRAINT fk_events_venue  FOREIGN KEY (venue_id)  REFERENCES venues (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Newsletter alert subscribers: double opt-in from day one. The confirm
-- and unsubscribe tokens are separate and independent, so unsubscribing
-- never requires re-confirming, and a leaked confirm token cannot
-- unsubscribe anyone.
CREATE TABLE alert_subscribers (
  id                INT UNSIGNED     NOT NULL AUTO_INCREMENT,
  email             VARCHAR(254)     NOT NULL,           -- RFC 5321 max length
  artist_id         INT UNSIGNED     DEFAULT NULL,       -- NULL = all-events digest
  confirm_token     CHAR(32)         NOT NULL,
  confirmed_at      DATETIME         DEFAULT NULL,       -- NULL = pending, never mailed
  unsubscribe_token CHAR(32)         NOT NULL,
  created_at        DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_subs_email_artist (email, artist_id),     -- same fan, same artist, one row
  KEY idx_subs_pending (confirmed_at, created_at),
  KEY idx_subs_artist (artist_id),
  CONSTRAINT fk_subs_artist FOREIGN KEY (artist_id) REFERENCES artists (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

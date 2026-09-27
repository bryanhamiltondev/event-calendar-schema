pdo = $pdo;
        // Fail loudly and early in development; never emulated prepares.
        $this->pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $this->pdo->setAttribute(PDO::ATTR_EMULATE_PREPARES, false);
    }

    /**
     * Upsert an event from an ingestion run. Idempotent by design: the
     * UNIQUE KEY (artist_id, venue_id, event_date) makes replaying the
     * same feed an UPDATE, never a duplicate row - no SELECT-then-INSERT
     * race window exists because the database is the arbiter.
     *
     * @return string 'inserted' | 'updated' | 'unchanged'
     */
    public function upsertEvent(array $e)
    {
        $sql = "INSERT INTO events
                    (artist_id, venue_id, source, source_event_id,
                     event_date, timezone, ticket_url, is_sold_out)
                VALUES
                    (:artist_id, :venue_id, :source, :source_event_id,
                     :event_date, :timezone, :ticket_url, :is_sold_out)
                ON DUPLICATE KEY UPDATE
                    source_event_id = VALUES(source_event_id),
                    ticket_url      = VALUES(ticket_url),
                    is_sold_out     = VALUES(is_sold_out),
                    is_active       = 1";

        $stmt = $this->pdo->prepare($sql);
        $stmt->execute(array(
            ':artist_id'       => $e['artist_id'],
            ':venue_id'        => $e['venue_id'],
            ':source'          => $e['source'],
            ':source_event_id' => $e['source_event_id'],
            ':event_date'      => $e['event_date'],
            ':timezone'        => $e['timezone'],
            ':ticket_url'      => $e['ticket_url'],
            ':is_sold_out'     => (int) $e['is_sold_out'],
        ));

        // rowCount() on an upsert: 1 = insert, 2 = update, 0 = no change.
        $affected = $stmt->rowCount();
        if ($affected === 2) {
            return 'updated';
        }
        if ($affected === 1) {
            return 'inserted';
        }
        return 'unchanged';
    }

    /**
     * The site's hottest query: the next N upcoming shows for an artist,
     * cutoff at "now", soft-deleted rows excluded. Served by
     * idx_events_artist_date (artist_id, event_date).
     *
     * @return array[]
     */
    public function findUpcomingByArtist($artistId, $limit = 25)
    {
        $stmt = $this->pdo->prepare(
            "SELECT e.id, e.event_date, e.timezone, e.ticket_url, e.is_sold_out,
                    v.name AS venue_name, v.city, v.region, v.country, v.lat, v.lng
               FROM events e
          LEFT JOIN venues v ON v.id = e.venue_id
              WHERE e.artist_id = :artist_id
                AND e.is_active = 1
                AND e.event_date >= :cutoff
           ORDER BY e.event_date ASC
              LIMIT :limit"
        );
        $stmt->bindValue(':artist_id', (int) $artistId, PDO::PARAM_INT);
        $stmt->bindValue(':cutoff', gmdate('Y-m-d H:i:s'));
        $stmt->bindValue(':limit', (int) $limit, PDO::PARAM_INT);
        $stmt->execute();

        return $stmt->fetchAll(PDO::FETCH_ASSOC);
    }

    /**
     * Double opt-in, step 1: register intent. INSERT IGNORE under the
     * (email, artist_id) UNIQUE key, so re-requesting never errors and
     * never duplicates - it just re-issues the confirm link.
     *
     * @return string the confirm token (existing or fresh)
     */
    public function createSubscription($email, $artistId = null)
    {
        $confirm     = bin2hex(random_bytes(16));
        $unsubscribe = bin2hex(random_bytes(16));

        $stmt = $this->pdo->prepare(
            "INSERT IGNORE INTO alert_subscribers
                        (email, artist_id, confirm_token, unsubscribe_token)
             VALUES     (:email, :artist_id, :confirm_token, :unsubscribe_token)"
        );
        $stmt->bindValue(':email', $email);
        $stmt->bindValue(':artist_id', $artistId === null ? null : (int) $artistId, PDO::PARAM_INT);
        $stmt->bindValue(':confirm_token', $confirm);
        $stmt->bindValue(':unsubscribe_token', $unsubscribe);
        $stmt->execute();

        if ($stmt->rowCount() === 1) {
            return $confirm;
        }

        // Row already existed: re-issue a fresh confirm token for this
        // request so a stale link cannot be the only path in.
        $fresh = bin2hex(random_bytes(16));
        $upd = $this->pdo->prepare(
            "UPDATE alert_subscribers
                SET confirm_token = :token
              WHERE email = :email
                AND artist_id " . ($artistId === null ? "IS NULL" : "= :artist_id")
        );
        $upd->bindValue(':token', $fresh);
        $upd->bindValue(':email', $email);
        if ($artistId !== null) {
            $upd->bindValue(':artist_id', (int) $artistId, PDO::PARAM_INT);
        }
        $upd->execute();

        return $fresh;
    }

    /**
     * Double opt-in, step 2: only a valid confirm token flips confirmed_at,
     * and only while still pending.
     */
    public function confirmSubscription($token)
    {
        $stmt = $this->pdo->prepare(
            "UPDATE alert_subscribers
                SET confirmed_at = NOW()
              WHERE confirm_token = :token
                AND confirmed_at IS NULL"
        );
        $stmt->execute(array(':token' => $token));

        return $stmt->rowCount() === 1;
    }

    /**
     * Unsubscribe by token. Independent of the confirm token by design:
     * a leaked confirmation token must never let anyone unsubscribe a fan.
     */
    public function unsubscribe($token)
    {
        $stmt = $this->pdo->prepare(
            "DELETE FROM alert_subscribers WHERE unsubscribe_token = :token"
        );
        $stmt->execute(array(':token' => $token));

        return $stmt->rowCount() === 1;
    }
}

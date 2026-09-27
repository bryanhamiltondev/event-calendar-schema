event-calendar-schema

Representative excerpt of the MySQL schema and PDO data layer behind
The DJ Calendar (https://thedjcalendar.com)'s event pipeline: how a
thousand-page event discovery platform models artists, venues, events, and
newsletter alert subscribers - and why.

The column sets are representative, not the live schema. The design
decisions are the real thing.

The schema, in one paragraph

artists and venues carry natural keys (name_normalized,
(name, city, country)) because third-party feeds identify entities by
name, not by ID - the database is the dedupe authority. events carries a
UNIQUE key (artist_id, venue_id, event_date) that makes feed re-ingestion
idempotent: replaying the same source data produces UPDATEs, never
duplicates. alert_subscribers implements double opt-in with two
independent tokens: confirming and unsubscribing are separate capabilities,
so one leaked token cannot grant the other.

Design decisions

| Decision                                         | Why                                                                                                                                                                   |
| ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Natural-key UNIQUE constraints                   | Feeds replay. The dedupe must survive a process crash mid-ingest, so it lives in the database, not in application memory.                                             |
| ON DUPLICATE KEY UPDATE, not SELECT-then-INSERT  | The read-then-write pattern has a race window under concurrent ingestion runs; the atomic upsert has none.                                                            |
| Soft delete on events (is_active)                | Ingestion must never hard-delete on a feed hiccup: an empty source payload is a data problem, not an instruction to erase history.                                    |
| event_date stored UTC + separate timezone column | Display localizes later; comparisons always normalize. Storing localized datetimes is how "8 PM show" becomes "3 AM email blast".                                     |
| Composite indexes match query shape              | idx_events_upcoming (is_active, event_date) exists for the site's hottest query (next N shows); idx_events_artist_date serves artist pages. No index without a query. |
| Two independent subscriber tokens                | Confirm and unsubscribe are different security capabilities with different blast radii; one token must never do both.                                                 |
| utf8mb4 + name_normalized                        | Artist names are international text; search that breaks on diacritics is broken search.                                                                               |

The data layer

includes/EventRepository.php - PDO, prepared statements only, with
ATTR_EMULATE_PREPARES off so every statement is a true server-side
prepared statement:

- upsertEvent() - the idempotent ingestion write, returning
  inserted / updated / unchanged (decoded from rowCount()'s
  upsert semantics: 1 = insert, 2 = update, 0 = no change)
- findUpcomingByArtist() - the hottest read, shaped for its composite
  index, cutoff at "now"
- createSubscription() / confirmSubscription() / unsubscribe() -
  the double opt-in lifecycle

Scope

Schema excerpts are representative versions of the production design:
column names and sets are simplified, and the ingestion pipeline, proxy
caching layer, and admin tooling are not included.

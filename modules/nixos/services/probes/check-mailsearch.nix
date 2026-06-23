# Deep write-path probe for the mailsearch index.
#
# Why this exists:
#   The shallow heartbeat (mailsearch-health) is touched whenever a
#   mailsearch-index run SUCCEEDS — even if the embed leg silently embedded
#   nothing (embed server down, dimension mismatch, llama-server hang). So a
#   green heartbeat does NOT prove the vector store is being maintained. This is
#   the Immich-#250 silent-degradation shape: every shallow monitor stays green
#   while a feature is quietly broken.
#
# What it checks (any failure exits non-zero -> Kuma DOWN):
#   1. The embeddings server answers /health.
#   2. notmuch has indexed messages (keyword leg alive).
#   3. The vector store is not catastrophically empty given a real corpus
#      (catches an embed leg that has NEVER produced vectors).
#   4. Optional: the keyword/vector lag stays under MAILSEARCH_MAX_LAG (default
#      0 = disabled, so the one-time bootstrap backlog does not false-page;
#      set it post-bootstrap to catch a steady-state embed stall).
#
# Env: NOTMUCH_CONFIG, MAILSEARCH_VECTOR_DB, MAILSEARCH_EMBED_HEALTH_URL.
{pkgs}:
pkgs.writeShellApplication {
  name = "check-mailsearch";
  runtimeInputs = with pkgs; [notmuch sqlite curl coreutils];
  text = ''
    set -uo pipefail

    vector_db="''${MAILSEARCH_VECTOR_DB:?MAILSEARCH_VECTOR_DB not set}"
    health_url="''${MAILSEARCH_EMBED_HEALTH_URL:?MAILSEARCH_EMBED_HEALTH_URL not set}"
    min_corpus="''${MAILSEARCH_MIN_CORPUS:-1000}"
    max_lag="''${MAILSEARCH_MAX_LAG:-0}"

    # Pre-bootstrap: the vector store doesn't exist yet — nothing to assert.
    if [ ! -f "$vector_db" ]; then
      echo "[probe] vector store not yet created ($vector_db) — bootstrapping" >&2
      exit 0
    fi

    # 1. Embeddings server reachable.
    if ! curl -sf --retry 3 --retry-delay 2 --max-time 10 -o /dev/null "$health_url"; then
      echo "[probe] embeddings server not answering $health_url" >&2
      exit 1
    fi

    # 2. Keyword index has messages.
    notmuch_count=$(notmuch count '*' 2>/dev/null || echo 0)
    if [ "$notmuch_count" -le 0 ]; then
      echo "[probe] notmuch index is empty" >&2
      exit 1
    fi

    # 3. Vector store non-empty once there is a real corpus.
    vector_count=$(sqlite3 "$vector_db" 'SELECT count(*) FROM messages' 2>/dev/null || echo 0)
    if [ "$notmuch_count" -gt "$min_corpus" ] && [ "$vector_count" -le 0 ]; then
      echo "[probe] $notmuch_count messages indexed but 0 embedded — embed leg broken" >&2
      exit 1
    fi

    # 4. Optional steady-state lag bound.
    if [ "$max_lag" -gt 0 ]; then
      lag=$((notmuch_count - vector_count))
      if [ "$lag" -gt "$max_lag" ]; then
        echo "[probe] embed lag $lag exceeds MAILSEARCH_MAX_LAG=$max_lag (keyword=$notmuch_count vector=$vector_count)" >&2
        exit 1
      fi
    fi

    exit 0
  '';
}

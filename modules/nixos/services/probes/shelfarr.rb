# Probe storage using the same UID, SQLite gem and mounts as Shelfarr.
require "sqlite3"
require "tempfile"
require "securerandom"

%w[production production_queue].each do |name|
  SQLite3::Database.new("/rails/storage/#{name}.sqlite3", flags: SQLite3::Constants::Open::READWRITE) do |db|
    db.busy_timeout = 5000
    db.execute("BEGIN IMMEDIATE")
    begin
      db.execute("CREATE TABLE _homelab_probe (value TEXT NOT NULL)")
      value = SecureRandom.hex(16)
      db.execute("INSERT INTO _homelab_probe VALUES (?)", [value])
      raise "SQLite write/read mismatch" unless db.get_first_value("SELECT value FROM _homelab_probe") == value
    ensure
      db.execute("ROLLBACK")
    end
    next unless name == "production_queue"

    # OCI readiness precedes Rails/queue startup. Activation can start this
    # probe immediately; allow workers to register, bounded by the outer timeout.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    loop do
      missing = %w[Worker Dispatcher Scheduler].reject do |kind|
        db.get_first_value("SELECT COUNT(*) FROM solid_queue_processes WHERE kind = ? AND last_heartbeat_at > datetime('now', '-5 minutes')", [kind]).positive?
      end
      break if missing.empty?
      raise "No recent #{missing.join(', ')} heartbeat" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 1
    end
  end
end

%w[/audiobooks /ebooks].each do |library|
  Tempfile.create([".shelfarr-probe-", ".tmp"], library) do |file|
    file.write("shelfarr storage probe")
    file.flush
    file.fsync
    file.rewind
    raise "Library write/read mismatch" unless file.read == "shelfarr storage probe"
  end
end
%w[/downloads/shelfarr /downloads/completed/shelfarr].each do |path|
  Dir.open(path, &:read)
end
puts "Shelfarr SQLite writes, worker heartbeats and library storage healthy"

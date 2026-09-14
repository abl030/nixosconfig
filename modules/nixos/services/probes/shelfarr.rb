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

    %w[Worker Dispatcher Scheduler].each do |kind|
      count = db.get_first_value("SELECT COUNT(*) FROM solid_queue_processes WHERE kind = ? AND last_heartbeat_at > datetime('now', '-5 minutes')", [kind])
      raise "No recent #{kind} heartbeat" unless count.positive?
    end
  end
end

Tempfile.create([".shelfarr-probe-", ".tmp"], "/audiobooks") do |file|
  file.write("shelfarr storage probe")
  file.flush
  file.fsync
  file.rewind
  raise "Library write/read mismatch" unless file.read == "shelfarr storage probe"
end
%w[/downloads/shelfarr /downloads/completed/shelfarr].each do |path|
  Dir.open(path, &:read)
end
puts "Shelfarr SQLite writes, worker heartbeats and library storage healthy"

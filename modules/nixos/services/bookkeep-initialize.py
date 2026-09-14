"""Bootstrap only an empty Bookkeep database before upstream's migrations.

Upstream #89: migrations assume the ORM base tables already exist. Never stamp
an existing application's schema; normal upstream migrations handle upgrades.
"""

import os

from alembic import command
from alembic.config import Config
from sqlalchemy import inspect

from app import models  # Registers all tables on Base.metadata.
from app.database import Base, engine

assert models.User.__table__ in Base.metadata.sorted_tables
os.chdir("/app/backend")
if set(inspect(engine).get_table_names()) <= {"alembic_version"}:
    Base.metadata.create_all(bind=engine)
    command.stamp(Config("/app/backend/alembic.ini"), "heads")
    print("Initialized empty Bookkeep schema from upstream ORM models", flush=True)

os.execv("/app/entrypoint.sh", ["/app/entrypoint.sh"])

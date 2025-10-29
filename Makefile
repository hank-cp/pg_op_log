EXTENSION = op_log
DATA = op_log--1.0.0.sql
REGRESS = op_log_test

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

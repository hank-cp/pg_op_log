CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS plv8;
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS op_log;

BEGIN;

SELECT plan(48);

CREATE TEMP TABLE temp_op_meta (
    op_type text,
    op_note text,
    revision_id text
);

INSERT INTO temp_op_meta (op_type, op_note, revision_id)
VALUES ('TEST', 'Initial operation', gen_random_uuid()::text);

CREATE TABLE test_users (
    id bigserial PRIMARY KEY,
    name text,
    email text,
    metadata jsonb,
    tags text[],
    settings jsonb,
    items jsonb,
    modified_at timestamp DEFAULT now(),
    modified_by text,
    deleted boolean DEFAULT false
);

SELECT has_table('data_op_log', 'data_op_log table should exist');

SELECT has_column('data_op_log', 'schema_name', 'data_op_log should have schema_name column');
SELECT has_column('data_op_log', 'table_name', 'data_op_log should have table_name column');
SELECT has_column('data_op_log', 'data_id', 'data_op_log should have data_id column');
SELECT has_column('data_op_log', 'modified_at', 'data_op_log should have modified_at column');
SELECT has_column('data_op_log', 'modified_by', 'data_op_log should have modified_by column');
SELECT has_column('data_op_log', 'op_type', 'data_op_log should have op_type column');
SELECT has_column('data_op_log', 'op_note', 'data_op_log should have op_note column');
SELECT has_column('data_op_log', 'revision_id', 'data_op_log should have revision_id column');
SELECT has_column('data_op_log', 'raw_data', 'data_op_log should have raw_data column');
SELECT has_column('data_op_log', 'diff', 'data_op_log should have diff column');
SELECT has_column('data_op_log', 'json_diff', 'data_op_log should have json_diff column');
SELECT has_column('data_op_log', 'action', 'data_op_log should have action column');

SELECT has_function('op_log_diff_normal', 'op_log_diff_normal function should exist');
SELECT has_function('op_log_diff_array', 'op_log_diff_array function should exist');
SELECT has_function('op_log_diff_object', 'op_log_diff_object function should exist');
SELECT has_function('op_log_diff_object_array', 'op_log_diff_object_array function should exist');
SELECT has_function('op_log_diff_other', 'op_log_diff_other function should exist');
SELECT has_function('op_log_get_primary_key', 'op_log_get_primary_key function should exist');
SELECT has_function('op_log_enable', 'op_log_enable function should exist');
SELECT has_function('op_log_disable', 'op_log_disable function should exist');
SELECT has_function('op_log_trigger', 'op_log_trigger function should exist');

SELECT op_log_enable(
    'test_users'::regclass,
    ARRAY['deleted']::text[],
    '{"metadata": {"type": "object"}, "settings": {"type": "other"}, "items": {"type": "objectArray", "keyFields": ["id"]}}'::jsonb,
    ARRAY['tags']::text[]
);

UPDATE temp_op_meta SET op_type = 'CREATE', op_note = 'Test insert';

INSERT INTO test_users (name, email, metadata, tags, settings, items, modified_by)
VALUES (
    'Alice',
    'alice@example.com',
    '{"age": 30, "city": "Beijing"}'::jsonb,
    ARRAY['user', 'admin'],
    '{"theme": "dark"}'::jsonb,
    '[{"id": 1, "name": "item1", "value": 100}]'::jsonb,
    'system'
);

SELECT is(
    (SELECT COUNT(*)::int FROM data_op_log WHERE table_name = 'test_users' AND action = 'I'),
    1,
    'INSERT should create one log entry'
);

SELECT is(
    (SELECT action FROM data_op_log WHERE table_name = 'test_users' ORDER BY id DESC LIMIT 1),
    'I',
    'Action should be I for INSERT'
);

SELECT is(
    (SELECT op_type FROM data_op_log WHERE table_name = 'test_users' ORDER BY id DESC LIMIT 1),
    'CREATE',
    'op_type should be extracted from temp_op_meta'
);

SELECT is(
    (SELECT op_note FROM data_op_log WHERE table_name = 'test_users' ORDER BY id DESC LIMIT 1),
    'Test insert',
    'op_note should be extracted from temp_op_meta'
);

SELECT is(
    (SELECT modified_by FROM data_op_log WHERE table_name = 'test_users' ORDER BY id DESC LIMIT 1),
    'system',
    'modified_by should be extracted from record'
);

SELECT is(
    (SELECT raw_data->>'name' FROM data_op_log WHERE table_name = 'test_users' AND action = 'I' ORDER BY id DESC LIMIT 1),
    'Alice',
    'raw_data should contain record data for INSERT'
);

SELECT isnt(
    (SELECT raw_data FROM data_op_log WHERE table_name = 'test_users' AND action = 'I' ORDER BY id DESC LIMIT 1),
    NULL,
    'raw_data should not be NULL for INSERT'
);

UPDATE temp_op_meta SET op_type = 'UPDATE', op_note = 'Test update';

UPDATE test_users
SET
    name = 'Alice Wang',
    metadata = '{"age": 31, "city": "Shanghai"}'::jsonb,
    tags = ARRAY['user', 'premium'],
    settings = '{"theme": "light"}'::jsonb,
    items = '[{"id": 1, "name": "item1", "value": 150}, {"id": 2, "name": "item2", "value": 200}]'::jsonb,
    modified_by = 'admin',
    modified_at = now()
WHERE id = 1;

SELECT is(
    (SELECT COUNT(*)::int FROM data_op_log WHERE table_name = 'test_users' AND action = 'U'),
    1,
    'UPDATE should create one log entry'
);

SELECT is(
    (SELECT action FROM data_op_log WHERE table_name = 'test_users' AND action = 'U' ORDER BY id DESC LIMIT 1),
    'U',
    'Action should be U for UPDATE'
);

SELECT isnt(
    (SELECT diff FROM data_op_log WHERE table_name = 'test_users' AND action = 'U' ORDER BY id DESC LIMIT 1),
    NULL,
    'diff should not be NULL for UPDATE'
);

SELECT is(
    (SELECT diff->>'diffType' FROM data_op_log WHERE table_name = 'test_users' AND action = 'U' ORDER BY id DESC LIMIT 1),
    'normal',
    'diff should have diffType normal'
);

SELECT is(
    (SELECT diff->>'name' FROM data_op_log WHERE table_name = 'test_users' AND action = 'U' ORDER BY id DESC LIMIT 1),
    '"Alice" -> "Alice Wang"',
    'diff should show name change correctly'
);

SELECT isnt(
    (SELECT json_diff FROM data_op_log WHERE table_name = 'test_users' AND action = 'U' ORDER BY id DESC LIMIT 1),
    NULL,
    'json_diff should not be NULL for UPDATE with json fields'
);

SELECT is(
    (SELECT json_diff->'metadata'->>'diffType' FROM data_op_log WHERE table_name = 'test_users' AND action = 'U' ORDER BY id DESC LIMIT 1),
    'object',
    'metadata diff should have diffType object'
);

SELECT is(
    (SELECT json_diff->'metadata'->>'age' FROM data_op_log WHERE table_name = 'test_users' AND action = 'U' ORDER BY id DESC LIMIT 1),
    '30 -> 31',
    'metadata diff should show age change'
);

SELECT is(
    (SELECT json_diff->'metadata'->>'city' FROM data_op_log WHERE table_name = 'test_users' AND action = 'U' ORDER BY id DESC LIMIT 1),
    '"Beijing" -> "Shanghai"',
    'metadata diff should show city change'
);

SELECT is(
    (SELECT json_diff->'tags'->>'diffType' FROM data_op_log WHERE table_name = 'test_users' AND action = 'U' ORDER BY id DESC LIMIT 1),
    'array',
    'tags diff should have diffType array'
);

SELECT ok(
    (SELECT json_diff->'tags'->'newItems' @> '["premium"]'::jsonb FROM data_op_log WHERE table_name = 'test_users' AND action = 'U' ORDER BY id DESC LIMIT 1),
    'tags diff should show premium as new item'
);

SELECT ok(
    (SELECT json_diff->'tags'->'removedItems' @> '["admin"]'::jsonb FROM data_op_log WHERE table_name = 'test_users' AND action = 'U' ORDER BY id DESC LIMIT 1),
    'tags diff should show admin as removed item'
);

SELECT is(
    (SELECT json_diff->'settings'->>'diffType' FROM data_op_log WHERE table_name = 'test_users' AND action = 'U' ORDER BY id DESC LIMIT 1),
    'other',
    'settings diff should have diffType other'
);

SELECT is(
    (SELECT json_diff->'items'->>'diffType' FROM data_op_log WHERE table_name = 'test_users' AND action = 'U' ORDER BY id DESC LIMIT 1),
    'objectArray',
    'items diff should have diffType objectArray'
);

SELECT is(
    (SELECT jsonb_array_length(json_diff->'items'->'newItems') FROM data_op_log WHERE table_name = 'test_users' AND action = 'U' ORDER BY id DESC LIMIT 1),
    1,
    'items diff should show 1 new item'
);

SELECT is(
    (SELECT jsonb_array_length(json_diff->'items'->'modifiedItems') FROM data_op_log WHERE table_name = 'test_users' AND action = 'U' ORDER BY id DESC LIMIT 1),
    1,
    'items diff should show 1 modified item'
);

UPDATE temp_op_meta SET op_type = 'DELETE', op_note = 'Test delete';

DELETE FROM test_users WHERE id = 1;

SELECT is(
    (SELECT COUNT(*)::int FROM data_op_log WHERE table_name = 'test_users' AND action = 'D'),
    1,
    'DELETE should create one log entry'
);

SELECT is(
    (SELECT action FROM data_op_log WHERE table_name = 'test_users' AND action = 'D' ORDER BY id DESC LIMIT 1),
    'D',
    'Action should be D for DELETE'
);

SELECT is(
    (SELECT raw_data->>'name' FROM data_op_log WHERE table_name = 'test_users' AND action = 'D' ORDER BY id DESC LIMIT 1),
    'Alice Wang',
    'raw_data should contain deleted record data'
);

-- DROP TABLE test_users;
-- DROP TABLE temp_op_meta;

SELECT * FROM finish();

ROLLBACK;

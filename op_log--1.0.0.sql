CREATE TABLE IF NOT EXISTS data_op_log (
	id bigserial primary key,
    modified_at TIMESTAMP,
    modified_by text,

	schema_name text not null,
	table_name text not null,
	data_id text,
	op_type text,
	op_note text,
	revision_id text,
	raw_data jsonb,
	diff jsonb,
	json_diff jsonb,

	relid oid not null,
	session_user_name text,
	action_tstamp_tx TIMESTAMP NOT NULL,
	action_tstamp_stm TIMESTAMP NOT NULL,
	action_tstamp_clk TIMESTAMP NOT NULL,
	transaction_id bigint,
	client_addr inet,
	client_port integer,
	client_query text,
	action TEXT NOT NULL CHECK (action IN ('I', 'D', 'U', 'T')),
	statement_only boolean not null
);

CREATE INDEX IF NOT EXISTS data_op_log_schema_table_idx ON data_op_log(schema_name, table_name);
CREATE INDEX IF NOT EXISTS data_op_log_data_id_idx ON data_op_log(schema_name, table_name, data_id);

CREATE OR REPLACE FUNCTION op_log_diff_normal(old_record jsonb, new_record jsonb, excluded_fields text[])
RETURNS jsonb AS $$
	const old_obj = old_record || {};
	const new_obj = new_record || {};
	const excluded = excluded_fields || [];
	const result = { diffType: 'normal' };

	const all_keys = new Set([...Object.keys(old_obj), ...Object.keys(new_obj)]);

	for (const key of all_keys) {
		if (excluded.includes(key)) continue;

		const old_val = old_obj[key];
		const new_val = new_obj[key];

		if (old_val === new_val) continue;

		const old_str = old_val === null ? 'null' : JSON.stringify(old_val);
		const new_str = new_val === null ? 'null' : JSON.stringify(new_val);

		result[key] = old_str + ' -> ' + new_str;
	}

	return result;
$$ LANGUAGE plv8 IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION op_log_diff_array(old_array jsonb, new_array jsonb)
RETURNS jsonb AS $$
	const old_arr = Array.isArray(old_array) ? old_array : [];
	const new_arr = Array.isArray(new_array) ? new_array : [];

	const old_set = new Set(old_arr.map(v => JSON.stringify(v)));
	const new_set = new Set(new_arr.map(v => JSON.stringify(v)));

	const new_items = [];
	const removed_items = [];

	for (const item of new_arr) {
		const str_item = JSON.stringify(item);
		if (!old_set.has(str_item)) {
			new_items.push(item);
		}
	}

	for (const item of old_arr) {
		const str_item = JSON.stringify(item);
		if (!new_set.has(str_item)) {
			removed_items.push(item);
		}
	}

	return {
		diffType: 'array',
		newItems: new_items,
		removedItems: removed_items
	};
$$ LANGUAGE plv8 IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION op_log_diff_object(old_obj jsonb, new_obj jsonb)
RETURNS jsonb AS $$
	const old_record = old_obj || {};
	const new_record = new_obj || {};
	const result = { diffType: 'object' };

	const all_keys = new Set([...Object.keys(old_record), ...Object.keys(new_record)]);

	for (const key of all_keys) {
		const old_val = old_record[key];
		const new_val = new_record[key];

		if (old_val === new_val) continue;

		const old_str = old_val === null ? 'null' : JSON.stringify(old_val);
		const new_str = new_val === null ? 'null' : JSON.stringify(new_val);

		result[key] = old_str + ' -> ' + new_str;
	}

	return result;
$$ LANGUAGE plv8 IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION op_log_diff_object_array(old_array jsonb, new_array jsonb, key_fields text[])
RETURNS jsonb AS $$
	const old_arr = Array.isArray(old_array) ? old_array : [];
	const new_arr = Array.isArray(new_array) ? new_array : [];
	const keys = key_fields || ['id'];

	function get_key(obj) {
		return keys.map(k => obj[k]).join('∆');
	}

	const old_map = {};
	const new_map = {};

	for (const item of old_arr) {
		old_map[get_key(item)] = item;
	}

	for (const item of new_arr) {
		new_map[get_key(item)] = item;
	}

	const new_items = [];
	const removed_items = [];
	const modified_items = [];

	for (const key in new_map) {
		if (!(key in old_map)) {
			new_items.push(new_map[key]);
		} else {
			const old_item = old_map[key];
			const new_item = new_map[key];
			const diff = {};
			let has_diff = false;

			const all_keys = new Set([...Object.keys(old_item), ...Object.keys(new_item)]);

			for (const field of all_keys) {
				const old_val = old_item[field];
				const new_val = new_item[field];

				if (old_val === new_val) continue;

				const old_str = old_val === null ? 'null' : JSON.stringify(old_val);
				const new_str = new_val === null ? 'null' : JSON.stringify(new_val);

				diff[field] = old_str + ' -> ' + new_str;
				has_diff = true;
			}

			if (has_diff) {
				diff.key = key;
				modified_items.push(diff);
			}
		}
	}

	for (const key in old_map) {
		if (!(key in new_map)) {
			removed_items.push(old_map[key]);
		}
	}

	return {
		diffType: 'objectArray',
		newItems: new_items,
		removedItems: removed_items,
		modifiedItems: modified_items
	};
$$ LANGUAGE plv8 IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION op_log_diff_other(old_val jsonb, new_val jsonb)
RETURNS jsonb AS $$
	const old_str = old_val === null ? 'null' : JSON.stringify(old_val);
	const new_str = new_val === null ? 'null' : JSON.stringify(new_val);

	return {
		diffType: 'other',
		content: old_str + ' -> ' + new_str
	};
$$ LANGUAGE plv8 IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION op_log_get_primary_key(target_table regclass)
RETURNS text[] AS $$
DECLARE
	pk_columns text[];
BEGIN
	SELECT array_agg(a.attname ORDER BY array_position(conkey, a.attnum))
	INTO pk_columns
	FROM pg_constraint c
	JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
	WHERE c.conrelid = target_table
	AND c.contype = 'p';

	RETURN COALESCE(pk_columns, ARRAY['id']);
END;
$$ LANGUAGE plpgsql STABLE STRICT;

CREATE OR REPLACE FUNCTION op_log_extract_pk_value(record_data hstore, pk_columns text[])
RETURNS text AS $$
DECLARE
	pk_values text[];
	col text;
BEGIN
	FOREACH col IN ARRAY pk_columns
	LOOP
		pk_values := array_append(pk_values, record_data -> col);
	END LOOP;

	RETURN array_to_string(pk_values, '∆');
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION op_log_get_temp_meta(field_name text)
RETURNS text AS $$
DECLARE
	result text;
	table_exists boolean;
BEGIN
	SELECT EXISTS (
		SELECT 1 FROM pg_tables
		WHERE schemaname LIKE 'pg_temp%' AND tablename = 'temp_op_meta'
	) INTO table_exists;

	IF NOT table_exists THEN
		RETURN NULL;
	END IF;

	EXECUTE format('SELECT %I FROM temp_op_meta LIMIT 1', field_name) INTO result;
	RETURN result;
EXCEPTION
	WHEN OTHERS THEN
		RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION op_log_trigger()
RETURNS TRIGGER AS $$
DECLARE
	op_log_config jsonb;
	excluded_fields text[];
	json_fields jsonb;
	array_fields text[];
	pk_columns text[];
	data_id_value text;
	old_hstore hstore;
	new_hstore hstore;
	old_json jsonb;
	new_json jsonb;
	normal_diff jsonb;
	json_diff_result jsonb := '{}';
	field_name text;
	field_config jsonb;
	field_type text;
	key_fields text[];
	op_type_val text;
	op_note_val text;
	revision_id_val text;
	modified_at_val timestamp;
	modified_by_val text;
	action_type text;
BEGIN
	SELECT current_setting('op_log.config_' || TG_TABLE_SCHEMA || '_' || TG_TABLE_NAME, true)::jsonb INTO op_log_config;

	IF op_log_config IS NULL THEN
		RETURN COALESCE(NEW, OLD);
	END IF;

	excluded_fields := ARRAY[]::text[];
	IF op_log_config->>'excludedFields' IS NOT NULL THEN
		SELECT array_agg(value::text)
		INTO excluded_fields
		FROM jsonb_array_elements_text(op_log_config->'excludedFields');
	END IF;

	json_fields := COALESCE(op_log_config->'jsonFields', '{}'::jsonb);

	array_fields := ARRAY[]::text[];
	IF op_log_config->>'arrayFields' IS NOT NULL THEN
		SELECT array_agg(value::text)
		INTO array_fields
		FROM jsonb_array_elements_text(op_log_config->'arrayFields');
	END IF;

	pk_columns := op_log_get_primary_key(TG_RELID);

	IF TG_OP = 'INSERT' THEN
		action_type := 'I';
		new_hstore := hstore(NEW);
		data_id_value := op_log_extract_pk_value(new_hstore, pk_columns);
		new_json := row_to_json(NEW)::jsonb;

		BEGIN
			modified_at_val := (new_hstore -> 'modified_at')::timestamp;
		EXCEPTION WHEN OTHERS THEN
			modified_at_val := NULL;
		END;

		modified_by_val := new_hstore -> 'modified_by';
	ELSIF TG_OP = 'UPDATE' THEN
		action_type := 'U';
		old_hstore := hstore(OLD);
		new_hstore := hstore(NEW);
		data_id_value := op_log_extract_pk_value(new_hstore, pk_columns);
		old_json := row_to_json(OLD)::jsonb;
		new_json := row_to_json(NEW)::jsonb;

		BEGIN
			modified_at_val := (new_hstore -> 'modified_at')::timestamp;
		EXCEPTION WHEN OTHERS THEN
			modified_at_val := NULL;
		END;

		modified_by_val := new_hstore -> 'modified_by';

		normal_diff := op_log_diff_normal(
			old_json,
			new_json,
			excluded_fields || array_fields || (SELECT array_agg(key) FROM jsonb_object_keys(json_fields) AS key)
		);

		FOR field_name IN SELECT jsonb_object_keys(json_fields)
		LOOP
			field_config := json_fields -> field_name;
			field_type := field_config->>'type';

			IF field_type = 'object' THEN
				json_diff_result := json_diff_result || jsonb_build_object(
					field_name,
					op_log_diff_object(old_json->field_name, new_json->field_name)
				);
			ELSIF field_type = 'array' THEN
				json_diff_result := json_diff_result || jsonb_build_object(
					field_name,
					op_log_diff_array(old_json->field_name, new_json->field_name)
				);
			ELSIF field_type = 'objectArray' THEN
				key_fields := ARRAY['id'];
				IF field_config->>'keyFields' IS NOT NULL THEN
					SELECT array_agg(value::text)
					INTO key_fields
					FROM jsonb_array_elements_text(field_config->'keyFields');
				END IF;

				json_diff_result := json_diff_result || jsonb_build_object(
					field_name,
					op_log_diff_object_array(old_json->field_name, new_json->field_name, key_fields)
				);
			ELSIF field_type = 'other' THEN
				json_diff_result := json_diff_result || jsonb_build_object(
					field_name,
					op_log_diff_other(old_json->field_name, new_json->field_name)
				);
			END IF;
		END LOOP;

		FOR field_name IN SELECT unnest(array_fields)
		LOOP
			json_diff_result := json_diff_result || jsonb_build_object(
				field_name,
				op_log_diff_array(old_json->field_name, new_json->field_name)
			);
		END LOOP;
	ELSIF TG_OP = 'DELETE' THEN
		action_type := 'D';
		old_hstore := hstore(OLD);
		data_id_value := op_log_extract_pk_value(old_hstore, pk_columns);
		old_json := row_to_json(OLD)::jsonb;

		BEGIN
			modified_at_val := (old_hstore -> 'modified_at')::timestamp;
		EXCEPTION WHEN OTHERS THEN
			modified_at_val := NULL;
		END;

		modified_by_val := old_hstore -> 'modified_by';
	END IF;

	op_type_val := op_log_get_temp_meta('op_type');
	op_note_val := op_log_get_temp_meta('op_note');
	revision_id_val := op_log_get_temp_meta('revision_id');

	INSERT INTO data_op_log (
		schema_name,
		table_name,
		data_id,
		modified_at,
		modified_by,
		op_type,
		op_note,
		revision_id,
		raw_data,
		diff,
		json_diff,
		relid,
		session_user_name,
		action_tstamp_tx,
		action_tstamp_stm,
		action_tstamp_clk,
		transaction_id,
		client_addr,
		client_port,
		client_query,
		action,
		statement_only
	) VALUES (
		TG_TABLE_SCHEMA,
		TG_TABLE_NAME,
		data_id_value,
		modified_at_val,
		modified_by_val,
		op_type_val,
		op_note_val,
		revision_id_val,
		CASE WHEN action_type IN ('I', 'D') THEN COALESCE(new_json, old_json) ELSE NULL END,
		CASE WHEN action_type = 'U' THEN normal_diff ELSE NULL END,
		CASE WHEN action_type = 'U' AND json_diff_result != '{}'::jsonb THEN json_diff_result ELSE NULL END,
		TG_RELID,
		session_user,
		transaction_timestamp(),
		statement_timestamp(),
		clock_timestamp(),
		txid_current(),
		inet_client_addr(),
		inet_client_port(),
		current_query(),
		action_type,
		TG_LEVEL = 'STATEMENT'
	);

	RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION op_log_enable(
	target_table regclass,
	excluded_fields text[] DEFAULT ARRAY[]::text[],
	json_fields jsonb DEFAULT '{}'::jsonb,
	array_fields text[] DEFAULT ARRAY[]::text[]
)
RETURNS void AS $$
DECLARE
	config jsonb;
	config_key text;
	schema_name text;
	table_name text;
BEGIN
	SELECT n.nspname, c.relname
	INTO schema_name, table_name
	FROM pg_class c
	JOIN pg_namespace n ON n.oid = c.relnamespace
	WHERE c.oid = target_table;

	config := jsonb_build_object(
		'excludedFields', to_jsonb(excluded_fields),
		'jsonFields', json_fields,
		'arrayFields', to_jsonb(array_fields)
	);

	config_key := 'op_log.config_' || schema_name || '_' || table_name;

	EXECUTE format('ALTER DATABASE %I SET %s = %L', current_database(), config_key, config::text);

	EXECUTE format('SET %s = %L', config_key, config::text);

	EXECUTE format(
		'CREATE TRIGGER op_log_trigger_insert
		AFTER INSERT ON %I.%I
		FOR EACH ROW EXECUTE FUNCTION op_log_trigger()',
		schema_name, table_name
	);

	EXECUTE format(
		'CREATE TRIGGER op_log_trigger_update
		AFTER UPDATE ON %I.%I
		FOR EACH ROW EXECUTE FUNCTION op_log_trigger()',
		schema_name, table_name
	);

	EXECUTE format(
		'CREATE TRIGGER op_log_trigger_delete
		AFTER DELETE ON %I.%I
		FOR EACH ROW EXECUTE FUNCTION op_log_trigger()',
		schema_name, table_name
	);

	RAISE NOTICE 'Op log enabled for table %.%', schema_name, table_name;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION op_log_disable(target_table regclass)
RETURNS void AS $$
DECLARE
	schema_name text;
	table_name text;
BEGIN
	SELECT n.nspname, c.relname
	INTO schema_name, table_name
	FROM pg_class c
	JOIN pg_namespace n ON n.oid = c.relnamespace
	WHERE c.oid = target_table;

	EXECUTE format('DROP TRIGGER IF EXISTS op_log_trigger_insert ON %I.%I', schema_name, table_name);
	EXECUTE format('DROP TRIGGER IF EXISTS op_log_trigger_update ON %I.%I', schema_name, table_name);
	EXECUTE format('DROP TRIGGER IF EXISTS op_log_trigger_delete ON %I.%I', schema_name, table_name);

	RAISE NOTICE 'Op log disabled for table %.%', schema_name, table_name;
END;
$$ LANGUAGE plpgsql;

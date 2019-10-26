--
-- EXPLAIN
--

-- helper functions for examining json explain output

-- return a json explain of given query
CREATE OR REPLACE FUNCTION json_explain(query text, variadic opts text[])
  RETURNS json LANGUAGE PLPGSQL AS $$
DECLARE
  plan json;
BEGIN
  EXECUTE 'EXPLAIN (' || array_to_string(array_append(opts, 'FORMAT JSON) '), ', ') || query INTO STRICT plan;
  RETURN plan;
END;
$$;

/*
 * Takes a json object and processes its keys and values. For every
 * matching key whose value is a number, set it to zero to facilitate
 * comparisons for values that can vary across executions. If not a number,
 * set the value to -1 to indicate we matched an unexpected key. Return
 * non-matching keys and values unmodified.
 */
CREATE OR REPLACE FUNCTION json_normalize_numeric_keys_matching(obj json, regexp text)
  RETURNS json LANGUAGE SQL AS $$
SELECT
  coalesce(json_object_agg(
    key,
    CASE
      WHEN key ~ regexp THEN
        CASE json_typeof(value)
	  WHEN 'number' THEN 0::text::json
	  ELSE (-1)::text::json
	END
      ELSE value
    END
  ), '{}')
FROM
  json_each(obj)
$$;

-- explain only worker information, normalizing any values that could vary across executions
CREATE OR REPLACE FUNCTION explain_workers(plan_node json)
  RETURNS json LANGUAGE SQL AS $$
SELECT
  coalesce(json_object_agg(key, value), '{}')
FROM (
  SELECT
    key,
    CASE key
      WHEN 'Workers' THEN
        (SELECT json_agg(
	   json_normalize_numeric_keys_matching(worker, '(Blocks|Time)$|Sort Space Used')
        )
        FROM json_array_elements(value) AS workers(worker))
      WHEN 'Plans' THEN
	(SELECT json_agg(
	  explain_workers(child)
	)
	FROM json_array_elements(value) AS children(child))
    END AS value
  FROM
    json_each(plan_node) AS entries(key, value)
  WHERE
    key IN ('Workers', 'Plans')
) AS plan_fields(key, value);
$$;

-- test that per-worker sort and buffers output is combined correctly in EXPLAIN
set force_parallel_mode = true;

SELECT explain_workers(json_explain($$
  SELECT * FROM (VALUES(1),(2)) x ORDER BY x;
$$, 'verbose', 'analyze', 'buffers') -> 0 -> 'Plan');

reset force_parallel_mode;

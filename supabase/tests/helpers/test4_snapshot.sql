
-- TEST4: every requested row count, all document counters and complete balance/unit states.
CREATE FUNCTION t.snapshot(o uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE result jsonb := '{}'::jsonb; name text; value jsonb;
BEGIN
  FOR name IN SELECT table_name::text FROM information_schema.columns WHERE table_schema='public' AND column_name='organization_id' AND table_name IN (SELECT tablename FROM pg_tables WHERE schemaname='public') ORDER BY table_name LOOP
    EXECUTE format('SELECT to_jsonb(count(*)) FROM public.%I WHERE organization_id=$1',name) INTO value USING o;
    result := result || jsonb_build_object(name,value);
  END LOOP;
  FOREACH name IN ARRAY ARRAY['document_counters','stock_levels','cash_balances','store_credit_balances','units'] LOOP
    EXECUTE format('SELECT COALESCE(jsonb_agg(j ORDER BY j::text),''[]''::jsonb) FROM (SELECT to_jsonb(x) j FROM public.%I x WHERE organization_id=$1) s',name) INTO value USING o;
    result := result || jsonb_build_object(name,value);
  END LOOP;
  RETURN result;
END $$;
GRANT EXECUTE ON FUNCTION t.snapshot(uuid) TO authenticated;
CREATE FUNCTION t.unchanged(n text,q text,c text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE before jsonb := t.snapshot(t.org('a'));
BEGIN
  PERFORM t.error(n,q,c);
  PERFORM t.expect(n||': full snapshot unchanged',t.snapshot(t.org('a'))=before);
END $$;
GRANT EXECUTE ON FUNCTION t.unchanged(text,text,text) TO authenticated;

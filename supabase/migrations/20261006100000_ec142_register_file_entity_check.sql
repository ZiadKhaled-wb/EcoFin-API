-- EC-142: register_file checks that the record a file points at belongs to the caller's shop.
-- Migration 20261006100000_ec142_register_file_entity_check.sql. Replaces public.register_file
-- (same signature, so callers and the grant stay); everything else is unchanged from F14
-- (20261005120000_f14_register_file.sql).
--
-- Before: p_entity_type / p_entity_id were stored as given. The API checked them (F05
-- assertSameOrg), but a direct call with the user's own JWT could point a file at another shop's
-- record. Now, after the permission check and before the INSERT:
--   * p_entity_type must be one of the API's ENTITY_TABLES (src/services/files.rules.ts);
--   * p_entity_id without p_entity_type is refused;
--   * p_entity_id must be a row of that table in the caller's shop, else NOT_FOUND (the same
--     answer as for a record that doesn't exist, so another shop's record isn't revealed).

CREATE OR REPLACE FUNCTION public.register_file(
    p_id          uuid,
    p_path        text,
    p_original_name text,
    p_mime        text,
    p_size_bytes  bigint,
    p_sha256      text,
    p_purpose     public.file_purpose,
    p_entity_type text,
    p_entity_id   uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid := app.require_permission(CASE p_purpose
        WHEN 'logo'             THEN 'org.settings_manage'
        WHEN 'product_image'    THEN 'catalog.manage'
        WHEN 'customer_id'      THEN 'customer.edit'
        WHEN 'survey_photo'     THEN 'survey.submit'
        WHEN 'signature'        THEN 'installment.create'
        WHEN 'contract_pdf'     THEN 'installment.create'
        WHEN 'promissory_note'  THEN 'installment.create'
        WHEN 'delivery_proof'   THEN 'delivery.manage'
        WHEN 'expense_receipt'  THEN 'expense.create'
        WHEN 'legal_document'   THEN 'legal.manage'
        WHEN 'import'           THEN 'import.data'
        WHEN 'export'           THEN 'export.data'
        WHEN 'other'            THEN 'org.settings_manage'
    END);
    v_org   uuid := app.current_org_id();
    v_table text;
    v_found boolean;
BEGIN
    IF p_id IS NULL OR p_path IS NULL OR p_mime IS NULL OR p_size_bytes IS NULL
       OR p_size_bytes < 0 OR p_purpose IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: id, path, mime, size and purpose are required'
            USING ERRCODE = 'P0001';
    END IF;

    -- The object must sit under the caller's own shop: '<org id>/...', no '.', '..' or backslash.
    IF left(p_path, length(v_org::text) + 1) <> v_org::text || '/'
       OR p_path ~ '\\' OR p_path ~ '(^|/)\.{1,2}(/|$)' THEN
        RAISE EXCEPTION 'FILE_PATH_INVALID: the path must start with the shop id' USING ERRCODE = 'P0001';
    END IF;

    -- EC-142: the record the file points at. Same entity types as the API (files.rules.ts ENTITY_TABLES).
    IF p_entity_id IS NOT NULL AND p_entity_type IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: an entity type is needed with an entity id' USING ERRCODE = 'P0001';
    END IF;
    IF p_entity_type IS NOT NULL THEN
        v_table := CASE p_entity_type
            WHEN 'customer'   THEN 'customers'
            WHEN 'product'    THEN 'products'
            WHEN 'expense'    THEN 'expenses'
            WHEN 'contract'   THEN 'contracts'
            WHEN 'legal_case' THEN 'legal_cases'
            WHEN 'delivery'   THEN 'deliveries'
        END;
        IF v_table IS NULL THEN
            RAISE EXCEPTION 'VALIDATION_FAILED: unknown entity type' USING ERRCODE = 'P0001';
        END IF;
        IF p_entity_id IS NOT NULL THEN
            EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I WHERE id = $1 AND organization_id = $2)', v_table)
                INTO v_found USING p_entity_id, v_org;
            IF NOT v_found THEN
                RAISE EXCEPTION 'NOT_FOUND: entity' USING ERRCODE = 'P0002';
            END IF;
        END IF;
    END IF;

    INSERT INTO public.files (id, organization_id, bucket, path, original_name, mime, size_bytes,
                              sha256, purpose, entity_type, entity_id, created_by)
    VALUES (p_id, v_org, 'tenant-files', p_path, p_original_name, p_mime, p_size_bytes,
            p_sha256, p_purpose, p_entity_type, p_entity_id, v_emp);

    PERFORM app.write_audit('file.upload', 'file', p_id, NULL,
        jsonb_build_object('purpose', p_purpose, 'size', p_size_bytes,
                           'entity_type', p_entity_type, 'entity_id', p_entity_id));
    RETURN p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.register_file(uuid, text, text, text, bigint, text,
                                               public.file_purpose, text, uuid) TO authenticated;
